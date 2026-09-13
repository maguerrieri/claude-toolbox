#!/bin/bash
# Install the plugins this repo declares in .claude/settings.json when running
# as a Claude Code cloud session.
#
# Cloud sessions honor repo-declared hooks but not repo-declared plugins: the
# loader skips anything "enabled only by repo-authored settings" (a consent
# policy — a cloned repo can't install code on its own), and the folder is
# never trusted there, so extraKnownMarketplaces isn't even registered. Doing
# the install from a SessionStart hook keeps settings.json the single source
# of truth: this script never needs editing when the plugin set changes.
# Delete it once cloud sessions honor enabledPlugins/extraKnownMarketplaces.
#
# Locally this is a no-op (CLAUDE_CODE_REMOTE is unset); interactive local
# sessions install the same plugins on the trust prompt. In this repo's factory
# implementer environment the plugins are already provisioned into the cached
# snapshot by origin/main's .claude/cloud-setup.sh (spec 2b), so the install
# loop below finds them installed and skips; it stays for sessions in any
# other environment and for the repos that run this file from the URL below.
#
# Other repos can copy this file, or run it straight from this repo with one
# hook line and no file to copy:
#   curl -fsSL https://raw.githubusercontent.com/maguerrieri/claude-toolbox/main/.claude/hooks/session-start.sh | bash
# (pin a commit SHA in place of `main` for an immutable copy). It reads the
# settings of whatever repo the hook runs in: Claude Code sets
# CLAUDE_PROJECT_DIR for hooks, and the working directory is the project too.
set -uo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Drift nudge (spec 2b): in a factory environment the VM was provisioned by
# origin/main's .claude/cloud-setup.sh via the GUI stub, and this per-session
# hook runs that same origin/main copy in --verify mode so a stale snapshot
# (SETUP STALE), a checkout whose .claude/ differs from main (UNTRUSTED
# .claude/), or a committed remote.* override lands in the session's context.
# It is the origin/main copy, not the checkout's, so a branch that edits the
# script cannot silence its own nudge -- though a branch can delete this hook,
# which is why it is a nudge and not a boundary. Never blocks; outside a
# factory environment it reports SETUP ABSENT and the install below proceeds.
if git fetch -q --depth=1 origin +refs/heads/main:refs/remotes/origin/main 2>/dev/null; then
  setup_script=$(git show origin/main:.claude/cloud-setup.sh 2>/dev/null || true)
  if [ -n "$setup_script" ]; then
    bash -c "$setup_script" cloud-setup --verify || true
  fi
else
  echo "cloud-setup: SETUP VERIFY SKIPPED: origin/main unreachable from the SessionStart hook"
fi

# Allowlist. Only these marketplaces are ever registered or installed from,
# whatever settings.json says. A repo-declared hook already runs arbitrary
# shell in cloud sessions, so this is defense in depth rather than a security
# boundary: it keeps a settings-only change on a branch or PR from pulling in a
# marketplace this hook was never meant to serve. Extend it here, in the
# script, not in settings.
allowed_source() {
  case "$1" in
    maguerrieri-toolbox) echo maguerrieri/claude-toolbox ;;
    claude-plugins-official) echo anthropics/claude-plugins-official ;;
  esac
}

settings_file="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json"
for tool in claude jq; do
  if ! command -v "$tool" >/dev/null; then
    echo "session-start: $tool not found; skipping plugin install" >&2
    exit 0
  fi
done
[ -f "$settings_file" ] || exit 0

installed=$(claude plugin list 2>/dev/null)
marketplaces=$(claude plugin marketplace list 2>/dev/null)

# One pass over the enabled plugins, each with its marketplace. `defaults`
# pulls its dependencies in; the explicit entries for those are then no-ops.
jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$settings_file" |
  while read -r plugin; do
    [ -n "$plugin" ] || continue
    marketplace="${plugin##*@}"
    source=$(allowed_source "$marketplace")
    if [ -z "$source" ]; then
      echo "session-start: skipping $plugin: marketplace $marketplace is not on this hook's allowlist" >&2
      continue
    fi
    declared=$(jq -r --arg m "$marketplace" '.extraKnownMarketplaces[$m].source.repo // empty' "$settings_file")
    if [ -n "$declared" ] && [ "$declared" != "$source" ]; then
      echo "session-start: skipping $plugin: settings declare $marketplace as $declared, expected $source" >&2
      continue
    fi
    # Register the marketplace once. The official one isn't in
    # extraKnownMarketplaces — Claude Code adds it itself, but asynchronously
    # after this hook has run — so it goes through the same path.
    #
    # Key on the marketplace NAME, not the source spelling: cloud-setup.sh
    # registers these as pinned git URLs (`Git (https://…git@main)`) while a
    # hook-added one shows the shorthand `(owner/repo)`, so matching the source
    # text would miss a provisioned snapshot and re-add on every session --
    # replacing the pinned registration with the unpinned shorthand.
    if ! awk -v name="$marketplace" '$1 == ">" && $2 == name { found = 1 } END { exit !found }' <<<"$marketplaces"; then
      if claude plugin marketplace add "$source" >/dev/null 2>&1; then
        marketplaces=$(claude plugin marketplace list 2>/dev/null)
      else
        echo "session-start: could not add marketplace $source; skipping $plugin" >&2
        continue
      fi
    fi
    # Already installed (a resume, or an earlier plugin's dependency): skip.
    grep -qF "> $plugin" <<<"$installed" && continue
    if claude plugin install "$plugin" >/dev/null 2>&1; then
      installed=$(claude plugin list 2>/dev/null)
    else
      echo "session-start: could not install $plugin" >&2
    fi
  done

exit 0
