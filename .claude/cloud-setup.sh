#!/bin/bash
# .claude/cloud-setup.sh -- provisioning for this repo's factory-implementer
# cloud environment (spec section 2b in
# docs/superpowers/specs/2026-09-11-software-factory-design.md, item 6).
#
# RULE: THIS SCRIPT NEVER EXECUTES ANYTHING FROM THE CHECKOUT. The environment
# runs the origin/main copy through the GUI-side stub recorded in spec 2b,
# never the checked-out branch's copy (a PR branch can be a cloud child's
# source_revision), and this script in turn: cds to a fresh temp directory
# before doing any work; invokes tools only from PATH as shipped in the VM
# image; reads the plugin list and the allowlist from origin/main, not the
# working tree; pins plugin installs to the marketplace at an explicit git ref;
# and contains no build-tool, package-manager, sourcing, or relative invocation
# that could pick up a Makefile, lockfile, or postinstall hook from the branch.
# ci-gate lints this file for such invocations (cloud_setup_lint in
# .github/scripts/ci_gate.py); the lint is a screen, this header is the rule.
#
# Modes:
#   (none)        provision: plugins (pinned), the logs-viewer key when this
#                 repo declares one, and the snapshot manifest. Run once per
#                 snapshot by the GUI stub; idempotent and re-runnable.
#   --verify      per-session drift nudge, run by .claude/hooks/session-start.sh
#                 against a fresh origin/main: prints SETUP STALE, UNTRUSTED
#                 .claude/, or PROJECT remote.* OVERRIDE PRESENT. Always exits
#                 0 -- a SessionStart hook cannot block a session anyway.
#   --assert-iam  IAM assertion for the active logs-viewer credential: it holds
#                 the logging.viewer permissions and none of the read/write
#                 permissions listed below. Exit 1 on excess, 2 if the check
#                 could not run.
#
# What this guards and what it does not (spec 2b): provisioning only. The
# result is a cached filesystem snapshot shared by every later session in the
# environment whatever that session's checkout, so nothing here is a
# per-session credential boundary. Only credentials whose full exposure to any
# branch is acceptable enter the VM: the IAM-scoped read-only logs key, and
# nothing else. Everything below that prints a marker is a nudge for humans
# reading the log.
set -euo pipefail

# --- Per-repo constants: the one place the two repos' copies differ. --------
# Empty GCP_PROJECT means this repo materializes no logs key.
GCP_PROJECT=""
LOGS_VIEWER_SA=""

# Marketplaces plugins may be installed from, pinned to a ref. Only these two
# are ever registered, whatever origin/main's settings.json enables.
MARKETPLACE_REF="main"
allowed_marketplace() {
  case "$1" in
    maguerrieri-toolbox) echo "https://github.com/maguerrieri/claude-toolbox.git#$MARKETPLACE_REF" ;;
    claude-plugins-official) echo "https://github.com/anthropics/claude-plugins-official.git#$MARKETPLACE_REF" ;;
  esac
}

# Permissions the logs key must hold (roles/logging.viewer) and a sample of
# read and write permissions it must not, checked with
# projects.testIamPermissions, which needs no permission of its own and
# changes nothing.
IAM_HELD="logging.logEntries.list logging.logs.list"
IAM_DENIED="run.services.list run.services.get run.services.create run.services.update run.services.delete
secretmanager.secrets.list secretmanager.secrets.create secretmanager.versions.access secretmanager.versions.add
logging.logEntries.create logging.logs.delete logging.sinks.create
storage.buckets.list storage.buckets.create
iam.serviceAccountKeys.create iam.serviceAccounts.actAs resourcemanager.projects.setIamPolicy
cloudbuild.builds.create artifactregistry.repositories.list"

mode="${1:-}"
repo_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
state_dir="${FACTORY_SETUP_STATE:-$HOME/.factory-setup}"
manifest="$state_dir/manifest"

say() { printf 'cloud-setup: %s\n' "$*"; }
die() { say "$*" >&2; exit 1; }

# Contents of a path on origin/main; empty when missing. Never the checkout.
main_blob() { git -C "$repo_dir" show "origin/main:$1" 2>/dev/null || true; }
hash_blob() { main_blob "$1" | sha256sum | cut -d' ' -f1; }
fetch_main() { git -C "$repo_dir" fetch -q --depth=1 origin +refs/heads/main:refs/remotes/origin/main; }

# Files under the checkout's .claude/ that differ from origin/main (tracked
# changes and untracked additions). A content comparison, never a branch-name
# test: cloud children are launched with their branch checked out and an
# unmodified .claude/ passes. Worktrees under .claude/worktrees/ are the ticket
# workflow's, not code, and are excluded.
claude_dir_drift() {
  {
    git -C "$repo_dir" diff --name-only origin/main -- .claude ':(exclude).claude/worktrees' 2>/dev/null || true
    git -C "$repo_dir" ls-files --others -- .claude ':(exclude).claude/worktrees' 2>/dev/null || true
  } | sed '/^$/d' | sort -u
}

# True when the checkout's .claude/settings.json carries a top-level remote /
# remote.* key (spec 2c: a manual `claude --cloud` from such a checkout lands
# wherever the branch says; ci-gate keeps the key off main).
remote_override() {
  local f="$repo_dir/.claude/settings.json"
  [ -f "$f" ] || return 1
  jq -e 'type == "object" and ([keys[] | select(. == "remote" or startswith("remote."))] | length > 0)' "$f" >/dev/null 2>&1
}

provision_plugins() {
  local settings marketplaces installed plugin market src
  if ! command -v claude >/dev/null || ! command -v jq >/dev/null; then
    say "claude or jq not on PATH; skipping plugin install"
    return 0
  fi
  settings=$(main_blob .claude/settings.json)
  [ -n "$settings" ] || { say "no .claude/settings.json on origin/main; skipping plugin install"; return 0; }
  marketplaces=$(claude plugin marketplace list 2>/dev/null || true)
  installed=$(claude plugin list 2>/dev/null || true)
  while read -r plugin; do
    [ -n "$plugin" ] || continue
    market="${plugin##*@}"
    src=$(allowed_marketplace "$market")
    if [ -z "$src" ]; then
      say "skipping $plugin: marketplace $market is not on this script's allowlist"
      continue
    fi
    if grep -qF "> $market" <<<"$marketplaces"; then
      claude plugin marketplace update "$market" >/dev/null 2>&1 || say "could not update marketplace $market"
    elif claude plugin marketplace add "$src" >/dev/null 2>&1; then
      marketplaces=$(claude plugin marketplace list 2>/dev/null || true)
    else
      say "could not add marketplace $src; skipping $plugin"
      continue
    fi
    grep -qF "> $plugin" <<<"$installed" && continue
    if claude plugin install "$plugin" >/dev/null 2>&1; then
      installed=$(claude plugin list 2>/dev/null || true)
      say "installed $plugin (marketplace pinned at $src)"
    else
      say "could not install $plugin"
    fi
  done < <(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' <<<"$settings")
}

# Writes the key into the gcloud config dir (the one in-VM credential) and
# asserts its IAM scope; a key that holds more than logging.viewer is revoked
# and fails provisioning.
provision_logs_key() {
  local key_file rc
  [ -n "$GCP_PROJECT" ] || { say "no GCP project declared for this repo; no logs key to materialize"; return 0; }
  command -v gcloud >/dev/null || { say "gcloud not on PATH; skipping the logs key"; return 0; }
  # The remote environment sets a token the GCP APIs reject and that overrides
  # any activated account; the SessionStart hook keeps it unset per session.
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  key_file="$work/logs-viewer-key.json"
  if [ -n "${FACTORY_LOGS_VIEWER_KEY:-}" ]; then
    case "$FACTORY_LOGS_VIEWER_KEY" in
      '{'*) printf '%s' "$FACTORY_LOGS_VIEWER_KEY" >"$key_file" ;;
      *) printf '%s' "$FACTORY_LOGS_VIEWER_KEY" | base64 -d >"$key_file" || die "FACTORY_LOGS_VIEWER_KEY is neither JSON nor base64" ;;
    esac
  elif [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && command -v op >/dev/null; then
    say "FACTORY_LOGS_VIEWER_KEY unset; fetching the key from 1Password (transitional: that token reaches its whole vault, so set FACTORY_LOGS_VIEWER_KEY on the environment instead and drop the op token)"
    if ! op document get gcp-logs-viewer-key --vault "Claude (personal)" --out-file "$key_file" --force >/dev/null; then
      say "could not fetch gcp-logs-viewer-key from 1Password; skipping gcloud auth"
      return 0
    fi
  else
    say "no logs key available (set FACTORY_LOGS_VIEWER_KEY on the environment); skipping gcloud auth"
    return 0
  fi
  if ! gcloud auth activate-service-account "$LOGS_VIEWER_SA" --key-file="$key_file" --quiet; then
    say "gcloud service-account activation failed; skipping gcloud auth"
    rm -f "$key_file"
    return 0
  fi
  rm -f "$key_file"
  gcloud config set project "$GCP_PROJECT" --quiet || true
  rc=0
  assert_iam || rc=$?
  if [ "$rc" -eq 1 ]; then
    say "logs key holds permissions beyond roles/logging.viewer; revoking it and failing provisioning"
    gcloud auth revoke "$LOGS_VIEWER_SA" --quiet || true
    return 1
  fi
  return 0
}

# 0 = scope as expected; 1 = excess or missing permission; 2 = could not check.
assert_iam() {
  local token body resp held p rc=0 t
  [ -n "$GCP_PROJECT" ] || { say "IAM: no GCP project declared for this repo; nothing to assert"; return 2; }
  for t in gcloud curl jq; do
    command -v "$t" >/dev/null || { say "IAM: $t not on PATH; cannot assert"; return 2; }
  done
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  token=$(gcloud auth print-access-token 2>/dev/null) || { say "IAM: no active gcloud credential; cannot assert"; return 2; }
  body=$(jq -cn --arg p "$IAM_HELD $IAM_DENIED" '{permissions: ($p | split(" ") | map(select(. != "")))}')
  if ! resp=$(curl -fsS -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      -d "$body" "https://cloudresourcemanager.googleapis.com/v1/projects/$GCP_PROJECT:testIamPermissions"); then
    say "IAM: testIamPermissions call failed; cannot assert"
    return 2
  fi
  held=$(jq -r '.permissions // [] | .[]' <<<"$resp")
  for p in $IAM_HELD; do
    grep -qx "$p" <<<"$held" || { say "IAM: $p is not held; the key is not the logs-viewer key"; rc=1; }
  done
  for p in $IAM_DENIED; do
    grep -qx "$p" <<<"$held" && { say "IAM: EXCESS $p is held"; rc=1; }
  done
  [ "$rc" -eq 0 ] && say "IAM OK: the active credential holds logging.viewer and none of the $(wc -w <<<"$IAM_DENIED") permissions tested beyond it"
  return "$rc"
}

write_manifest() {
  mkdir -p "$state_dir"
  {
    printf 'schema factory-setup/1\n'
    printf 'script %s\n' "$(hash_blob .claude/cloud-setup.sh)"
    printf 'allowlist %s\n' "$(hash_blob .claude/cloud-allowlist)"
    printf 'origin_main %s\n' "$(git -C "$repo_dir" rev-parse origin/main)"
    printf 'provisioned_at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$manifest"
  say "snapshot manifest written to $manifest"
}

provision() {
  local drift
  [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || die "$repo_dir is not a git checkout (set CLAUDE_PROJECT_DIR)"
  fetch_main || die "origin/main unreachable; refusing to provision"
  [ -n "$(main_blob .claude/cloud-setup.sh)" ] || die "origin/main has no .claude/cloud-setup.sh; refusing to provision"
  [ -n "$(main_blob .claude/cloud-allowlist)" ] || say "origin/main has no .claude/cloud-allowlist; the allowlist hash will not be tracked"
  provision_plugins
  drift=$(claude_dir_drift)
  if [ -n "$drift" ]; then
    say "UNTRUSTED .claude/: the checkout's .claude/ differs from origin/main ($(paste -sd, - <<<"$drift")); not materializing the logs key in this snapshot"
  else
    provision_logs_key
  fi
  if remote_override; then
    say "PROJECT remote.* OVERRIDE PRESENT: the checkout's .claude/settings.json carries a remote.* key (spec 2c)"
  fi
  write_manifest
}

verify() {
  local drift want_s want_a have_s have_a
  if ! fetch_main; then
    say "SETUP VERIFY SKIPPED: origin/main unreachable"
  else
    if [ ! -f "$manifest" ]; then
      say "SETUP ABSENT: no provisioning snapshot under $state_dir (not a factory environment, or its GUI stub has not run)"
    else
      want_s=$(hash_blob .claude/cloud-setup.sh)
      want_a=$(hash_blob .claude/cloud-allowlist)
      have_s=$(awk '$1 == "script" {print $2}' "$manifest")
      have_a=$(awk '$1 == "allowlist" {print $2}' "$manifest")
      if [ "$want_s" = "$have_s" ] && [ "$want_a" = "$have_a" ]; then
        say "SETUP OK: this snapshot matches origin/main's cloud-setup.sh and cloud-allowlist"
      else
        say "SETUP STALE: origin/main's cloud-setup.sh or cloud-allowlist changed after this snapshot was built; bump the (v1) comment in the GUI setup script, in each account, to rebuild it"
      fi
    fi
    drift=$(claude_dir_drift)
    if [ -n "$drift" ]; then
      say "UNTRUSTED .claude/: the checkout's .claude/ differs from origin/main ($(paste -sd, - <<<"$drift")); a drift nudge, not a boundary (spec 2b)"
    fi
  fi
  if remote_override; then
    say "PROJECT remote.* OVERRIDE PRESENT: .claude/settings.json carries a remote.* key; a manual claude --cloud from this checkout is not a trusted launch path (spec 2c)"
  fi
  return 0
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

case "$mode" in
  "") provision ;;
  --verify) verify ;;
  --assert-iam) assert_iam ;;
  *) die "unknown mode: $mode (expected none, --verify, or --assert-iam)" ;;
esac
