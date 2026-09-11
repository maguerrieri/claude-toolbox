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
# sessions install the same plugins on the trust prompt.
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

settings_file="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/settings.json"
for tool in claude jq; do
  if ! command -v "$tool" >/dev/null; then
    echo "session-start: $tool not found; skipping plugin install" >&2
    exit 0
  fi
done
[ -f "$settings_file" ] || exit 0

# Marketplaces first: github sources carry `repo`, git sources carry `url`.
# The official marketplace isn't in extraKnownMarketplaces — Claude Code adds
# it itself, but asynchronously after this hook has run — so register it here
# too whenever an enabled plugin comes from it.
{
  jq -r '.extraKnownMarketplaces // {} | to_entries[] | .value.source | (.repo // .url // empty)' "$settings_file"
  if jq -e '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key | endswith("@claude-plugins-official")' "$settings_file" >/dev/null; then
    echo anthropics/claude-plugins-official
  fi
} |
  while read -r source; do
    [ -n "$source" ] || continue
    # Already registered (a resume, or the launcher got there first): skip the clone.
    claude plugin marketplace list 2>/dev/null | grep -qF "($source)" && continue
    claude plugin marketplace add "$source" >/dev/null 2>&1 ||
      echo "session-start: could not add marketplace $source" >&2
  done

# Then every enabled plugin. `defaults` pulls its dependencies in; the explicit
# entries for those dependencies are then no-ops.
jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' "$settings_file" |
  while read -r plugin; do
    [ -n "$plugin" ] || continue
    # Already installed: skip. `claude plugin list` prints each as "> name@marketplace".
    claude plugin list 2>/dev/null | grep -qF "> $plugin" && continue
    claude plugin install "$plugin" >/dev/null 2>&1 ||
      echo "session-start: could not install $plugin" >&2
  done

exit 0
