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
#   --assert-iam  IAM assertion for the active logs-viewer credential: of every
#                 testable permission on the project it holds only ones in
#                 roles/logging.viewer. Exit 1 on excess, 2 if the check could
#                 not run, 0 (nothing to assert) in a repo with no GCP project.
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

# The one role the logs key may hold. --assert-iam reads that role's
# permission list from the IAM API, enumerates every testable permission on
# the project, asks projects.testIamPermissions (needs no permission of its
# own, changes nothing; IAM_BATCH names per call) which of them the active
# credential holds, and fails on any permission outside the role -- a full
# enumeration, not a sample, so a stray mutating grant anywhere is caught.
LOGS_VIEWER_ROLE="roles/logging.viewer"
IAM_CORE="logging.logEntries.list"
IAM_BATCH=100          # testIamPermissions accepts at most 100 names per call
IAM_MAX_PAGES=50       # a bound on the testable-permission listing, not a limit

# Secrets arrive as environment variables, and every child process inherits
# the environment -- including `claude plugin install` and whatever install
# hook a marketplace plugin runs. Capture them into shell variables, which are
# not exported, and drop the environment copies before any of that runs; the
# two places that need them pass them per-command.
factory_key="${FACTORY_LOGS_VIEWER_KEY:-}"
op_token="${OP_SERVICE_ACCOUNT_TOKEN:-}"
unset FACTORY_LOGS_VIEWER_KEY OP_SERVICE_ACCOUNT_TOKEN

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

# The `Source:` line `claude plugin marketplace list` prints for marketplace
# $1 (e.g. `Git (https://github.com/o/r.git@main)`), or empty if unregistered.
# Reads the caller's `$marketplaces` (the listing provision_plugins holds).
marketplace_source() {
  awk -v name="$1" '
    $1 == ">" { found = ($2 == name); next }
    found && /^[[:space:]]*Source:/ { sub(/^[[:space:]]*Source:[[:space:]]*/, ""); print; exit }
  ' <<<"$marketplaces"
}

# Non-zero on any failure that leaves origin/main's plugin set unrealized, so
# provision() withholds the manifest and the next setup run retries. A plugin
# whose marketplace is not on the allowlist is refused by policy, not a
# failure -- the refusal is the intended outcome.
provision_plugins() {
  local settings wanted marketplaces installed plugin market src registered reregistered=" " rc=0
  if ! command -v claude >/dev/null || ! command -v jq >/dev/null; then
    say "claude or jq not on PATH; cannot install the plugins origin/main enables"
    return 1
  fi
  settings=$(main_blob .claude/settings.json)
  [ -n "$settings" ] || { say "no .claude/settings.json on origin/main; no plugins to install"; return 0; }
  # Read the plugin list into a variable rather than a process substitution:
  # jq's exit status is discarded by `while ... < <(jq ...)`, so malformed JSON
  # or a non-object enabledPlugins would yield zero iterations, leave rc at 0,
  # and write a manifest claiming origin/main's plugin set was realized.
  if ! wanted=$(jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' <<<"$settings"); then
    say "origin/main's .claude/settings.json could not be read for enabledPlugins (invalid JSON, or enabledPlugins is not an object)"
    return 1
  fi
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
    # A marketplace already registered under this name counts only if its
    # source is exactly the pinned git URL and ref; a cached or
    # settings-registered entry of the same name (an unpinned GitHub source,
    # another repo) is replaced rather than updated in place.
    registered=$(marketplace_source "$market")
    if [ "$registered" = "Git (${src%%#*}@${src##*#})" ]; then
      claude plugin marketplace update "$market" >/dev/null 2>&1 || { say "could not update marketplace $market"; rc=1; continue; }
    else
      if [ -n "$registered" ]; then
        say "marketplace $market is registered from '$registered', not the pinned source; replacing it"
        claude plugin marketplace remove "$market" >/dev/null 2>&1 || { say "could not remove marketplace $market"; rc=1; continue; }
      fi
      if claude plugin marketplace add "$src" >/dev/null 2>&1; then
        marketplaces=$(claude plugin marketplace list 2>/dev/null || true)
        # This marketplace was (re-)registered in this run, so any install
        # of its plugins predates it and came from a source this script did
        # not pin -- the "already installed" shortcut below must not apply.
        reregistered="$reregistered$market "
      else
        say "could not add marketplace $src"
        rc=1
        continue
      fi
    fi
    case "$reregistered" in
      *" $market "*) ;;   # registered in this run: provenance unknown, reinstall
      *)
        if grep -qF "> $plugin" <<<"$installed"; then
          # `marketplace update` refreshes the catalog only -- an installed
          # plugin stays at the version it was installed at, and installs are
          # version-gated (AGENTS.md, Releasing), so a rebuilt snapshot that
          # already carries an older copy needs this to reach main's version.
          claude plugin update "$plugin" >/dev/null 2>&1 ||
            { say "could not update $plugin to the pinned marketplace's version"; rc=1; }
          continue
        fi ;;
    esac
    if claude plugin install "$plugin" >/dev/null 2>&1; then
      installed=$(claude plugin list 2>/dev/null || true)
      say "installed $plugin (marketplace pinned at $src)"
    else
      say "could not install $plugin"
      rc=1
    fi
  done <<<"$wanted"
  return "$rc"
}

# Writes the key into the gcloud config dir (the one in-VM credential) and
# asserts its IAM scope. A repo that declares a project fails provisioning
# (no snapshot manifest, so the next run retries) whenever the key cannot be
# obtained, activated, or proven in scope: a "successful" snapshot without
# the credential would report SETUP OK forever.
provision_logs_key() {
  local key_file
  [ -n "$GCP_PROJECT" ] || { say "no GCP project declared for this repo; no logs key to materialize"; return 0; }
  command -v gcloud >/dev/null || { say "gcloud not on PATH but this repo declares a logs key; failing provisioning"; return 1; }
  # The remote environment sets a token the GCP APIs reject and that overrides
  # any activated account; the SessionStart hook keeps it unset per session.
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  key_file="$work/logs-viewer-key.json"
  if [ -n "$factory_key" ]; then
    case "$factory_key" in
      '{'*) printf '%s' "$factory_key" >"$key_file" ;;
      *) printf '%s' "$factory_key" | base64 -d >"$key_file" || die "FACTORY_LOGS_VIEWER_KEY is neither JSON nor base64" ;;
    esac
  elif [ -n "$op_token" ] && command -v op >/dev/null; then
    say "FACTORY_LOGS_VIEWER_KEY unset; fetching the key from 1Password (transitional: that token reaches its whole vault, so set FACTORY_LOGS_VIEWER_KEY on the environment instead and drop the op token)"
    if ! OP_SERVICE_ACCOUNT_TOKEN="$op_token" op document get gcp-logs-viewer-key --vault "Claude (personal)" --out-file "$key_file" --force >/dev/null; then
      say "could not fetch gcp-logs-viewer-key from 1Password; failing provisioning"
      return 1
    fi
  else
    say "no logs key available (set FACTORY_LOGS_VIEWER_KEY on the environment); failing provisioning"
    return 1
  fi
  if ! gcloud auth activate-service-account "$LOGS_VIEWER_SA" --key-file="$key_file" --quiet; then
    say "gcloud service-account activation failed; failing provisioning"
    rm -f "$key_file"
    return 1
  fi
  rm -f "$key_file"
  if ! gcloud config set project "$GCP_PROJECT" --quiet; then
    say "could not set the gcloud project to $GCP_PROJECT; failing provisioning rather than leaving a session pointed at no project or a stale one"
    gcloud auth revoke "$LOGS_VIEWER_SA" --quiet || true
    return 1
  fi
  # Fail closed on any non-zero: an unproven scope (the check could not run)
  # is as unacceptable in a shared snapshot as a proven excess.
  if ! assert_iam; then
    say "logs key scope not proven (see the IAM lines above); deactivating it locally and failing provisioning"
    gcloud auth revoke "$LOGS_VIEWER_SA" --quiet || true
    # `gcloud auth revoke` only drops the credential from this VM's gcloud
    # config. The key stays valid in IAM and the environment variable still
    # holds it, and this credential cannot revoke itself -- deleting a key is
    # an IAM write, exactly what roles/logging.viewer must not have. So this
    # is an operator alarm, not enforcement: ROTATE THE KEY BY HAND.
    say "ACTION REQUIRED: the key is still valid in IAM and still set on the environment; delete that key and issue a logging.viewer-only replacement"
    return 1
  fi
  return 0
}

# 0 = scope as expected; 1 = excess or missing permission; 2 = could not
# check. A repo that declares no GCP project has nothing to assert (0).
iam_get() { curl -fsS --max-time 60 -H "Authorization: Bearer $token" "$1"; }
iam_post() { curl -fsS --max-time 60 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' -d "$2" "$1"; }
assert_iam() {
  local active token role_perms testable page_token page resp held excess missing batch n i t rc=0
  if [ -z "$GCP_PROJECT" ]; then
    say "IAM: no GCP project declared for this repo; nothing to assert"
    return 0
  fi
  for t in gcloud curl jq; do
    command -v "$t" >/dev/null || { say "IAM: $t not on PATH; cannot assert"; return 2; }
  done
  unset CLOUDSDK_AUTH_ACCESS_TOKEN
  # Which credential is being tested matters as much as what it holds: another
  # account with a subset of logging.viewer would otherwise print IAM OK.
  active=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
  if [ "$active" != "$LOGS_VIEWER_SA" ]; then
    say "IAM: the active gcloud account is '${active:-none}', not $LOGS_VIEWER_SA; cannot assert"
    return 2
  fi
  token=$(gcloud auth print-access-token 2>/dev/null) || { say "IAM: no active gcloud credential; cannot assert"; return 2; }
  # 1. The role's own permissions: the only ones the credential may hold.
  # `|| true`: under pipefail a failed curl would otherwise abort the whole
  # script with curl's status, and --assert-iam (called outside a condition,
  # where set -e is live) must report 2, not 22. An empty result is the signal.
  role_perms=$(iam_get "https://iam.googleapis.com/v1/$LOGS_VIEWER_ROLE" 2>/dev/null | jq -r '.includedPermissions[]?' | sort -u) || true
  [ -n "$role_perms" ] || { say "IAM: could not read $LOGS_VIEWER_ROLE from the IAM API; cannot assert"; return 2; }
  # 2. Every permission that can be tested on the project. Paginated at the
  #    server's own page size (no pageSize of ours to get wrong), bounded so a
  #    repeating nextPageToken cannot spin forever; permissions of disabled
  #    APIs cannot be exercised and are skipped.
  page_token=""
  page=0
  : >"$work/testable"
  while :; do
    resp=$(iam_post "https://iam.googleapis.com/v1/permissions:queryTestablePermissions" \
      "$(jq -cn --arg r "//cloudresourcemanager.googleapis.com/projects/$GCP_PROJECT" --arg p "$page_token" \
          '{fullResourceName: $r} + (if $p == "" then {} else {pageToken: $p} end)')") \
      || { say "IAM: could not enumerate the project's testable permissions; cannot assert"; return 2; }
    jq -r '.permissions[]? | select(.apiDisabled != true) | .name' <<<"$resp" >>"$work/testable"
    page_token=$(jq -r '.nextPageToken // empty' <<<"$resp")
    [ -n "$page_token" ] || break
    page=$((page + 1))
    [ "$page" -lt "$IAM_MAX_PAGES" ] || { say "IAM: the testable-permission listing did not end within $IAM_MAX_PAGES pages; cannot assert"; return 2; }
  done
  sort -u -o "$work/testable" "$work/testable"
  n=$(sed '/^$/d' "$work/testable" | wc -l)
  [ "$n" -gt 0 ] || { say "IAM: the project reports no testable permissions; cannot assert"; return 2; }
  # 3. Which of those the credential holds, IAM_BATCH names per call.
  : >"$work/held"
  i=1
  while [ "$i" -le "$n" ]; do
    batch=$(sed -n "${i},$((i + IAM_BATCH - 1))p" "$work/testable" | jq -R . | jq -cs '{permissions: .}')
    resp=$(iam_post "https://cloudresourcemanager.googleapis.com/v1/projects/$GCP_PROJECT:testIamPermissions" "$batch") \
      || { say "IAM: testIamPermissions call failed; cannot assert"; return 2; }
    jq -r '.permissions[]?' <<<"$resp" >>"$work/held"
    i=$((i + IAM_BATCH))
  done
  sort -u -o "$work/held" "$work/held"
  held=$(cat "$work/held")
  excess=$(comm -23 "$work/held" <(printf '%s\n' "$role_perms"))
  missing=$(comm -23 <(printf '%s\n' "$IAM_CORE" | sort -u) "$work/held")
  if [ -n "$excess" ]; then
    say "IAM: EXCESS: the credential holds permissions outside $LOGS_VIEWER_ROLE: $(paste -sd, - <<<"$excess")"
    rc=1
  fi
  if [ -n "$missing" ]; then
    say "IAM: $(paste -sd, - <<<"$missing") not held; the credential is not the logs-viewer key"
    rc=1
  fi
  [ "$rc" -eq 0 ] && say "IAM OK: of $n testable permissions on $GCP_PROJECT the credential holds $(sed '/^$/d' <<<"$held" | wc -l), all within $LOGS_VIEWER_ROLE"
  return "$rc"
}

write_manifest() {
  mkdir -p "$state_dir"
  {
    printf 'schema factory-setup/1\n'
    printf 'script %s\n' "$(hash_blob .claude/cloud-setup.sh)"
    printf 'allowlist %s\n' "$(hash_blob .claude/cloud-allowlist)"
    printf 'settings %s\n' "$(hash_blob .claude/settings.json)"
    printf 'origin_main %s\n' "$(git -C "$repo_dir" rev-parse origin/main)"
    printf 'provisioned_at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$manifest"
  say "snapshot manifest written to $manifest"
}

provision() {
  local drift rc=0
  [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || die "$repo_dir is not a git checkout (set CLAUDE_PROJECT_DIR)"
  fetch_main || die "origin/main unreachable; refusing to provision"
  [ -n "$(main_blob .claude/cloud-setup.sh)" ] || die "origin/main has no .claude/cloud-setup.sh; refusing to provision"
  # Not optional: the manifest's staleness check hashes it, and a missing file
  # hashes as empty input, so --verify would answer SETUP OK for a snapshot
  # whose reviewable network-allowlist mirror is not tracked at all.
  [ -n "$(main_blob .claude/cloud-allowlist)" ] || die "origin/main has no .claude/cloud-allowlist; refusing to provision"
  # Invalidate the previous snapshot's claim before touching anything. From
  # here the VM is mid-change, so the old manifest is no longer true; leaving
  # it would let --verify answer SETUP OK after a run that failed partway (or
  # deactivated the credential), and the hook would never retry.
  rm -f "$manifest"
  provision_plugins || rc=1
  drift=$(claude_dir_drift)
  if [ -n "$drift" ]; then
    say "UNTRUSTED .claude/: the checkout's .claude/ differs from origin/main ($(paste -sd, - <<<"$drift")); not materializing the logs key in this snapshot"
    # In a repo that declares a key, skipping it leaves the snapshot without
    # the credential; writing a manifest anyway would make the next clean
    # session read SETUP OK and never retry.
    [ -z "$GCP_PROJECT" ] || rc=1
  else
    provision_logs_key || rc=1
  fi
  if remote_override; then
    say "PROJECT remote.* OVERRIDE PRESENT: the checkout's .claude/settings.json carries a remote.* key (spec 2c)"
  fi
  # The manifest is the claim "this snapshot realizes origin/main". Write it
  # only when that is true; otherwise --verify would report SETUP OK against a
  # snapshot missing plugins or the credential, forever.
  [ "$rc" -eq 0 ] || die "provisioning incomplete (see the lines above); no snapshot manifest written, so the next setup run retries"
  write_manifest
}

verify() {
  local drift want_s want_a want_p have_s have_a have_p
  if ! fetch_main; then
    say "SETUP VERIFY SKIPPED: origin/main unreachable"
  else
    if [ ! -f "$manifest" ]; then
      say "SETUP ABSENT: no provisioning snapshot under $state_dir (not a factory environment, or its GUI stub has not run)"
    else
      want_s=$(hash_blob .claude/cloud-setup.sh)
      want_a=$(hash_blob .claude/cloud-allowlist)
      want_p=$(hash_blob .claude/settings.json)
      have_s=$(awk '$1 == "script" {print $2}' "$manifest")
      have_a=$(awk '$1 == "allowlist" {print $2}' "$manifest")
      have_p=$(awk '$1 == "settings" {print $2}' "$manifest")
      if [ "$want_s" = "$have_s" ] && [ "$want_a" = "$have_a" ] && [ "$want_p" = "$have_p" ]; then
        say "SETUP OK: this snapshot matches origin/main's cloud-setup.sh, cloud-allowlist, and settings.json"
      else
        say "SETUP STALE: origin/main's cloud-setup.sh, cloud-allowlist, or settings.json (the plugin set) changed after this snapshot was built; bump the (v1) comment in the GUI setup script, in each account, to rebuild it"
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
