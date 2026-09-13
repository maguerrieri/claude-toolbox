#!/usr/bin/env bash
# SessionStart — install the `gh` shim in a factory implementer session.
#
# Software-factory design 2d / item 8b. An implementer environment runs in
# pass-through mode with `GH_TOKEN` set to the sentinel `factory-token-required`,
# so *every* `gh` call needs the broker's token, not only the ones START Step 7
# spells out (the tracker's FETCH and DEPENDENCY_PR, `gh pr checks`, the
# review-thread queries, the epic's COORD markers). `factory-token` is a wrapper
# rather than an exporter — an `export` in one Bash call does not reach the next —
# so this hook puts a `gh` shim earlier on PATH that wraps every other invocation.
#
# Step 7 still calls `factory-token exec` explicitly for the push and
# `gh pr create`, so identity never depends on this hook: a branch that deletes it
# leaves those calls wrapped anyway, and any unwrapped `gh` reads the sentinel and
# fails rather than acting as the user. That is the fail-closed outcome 2d wants.
#
# No-op unless FACTORY_BROKER_URL is set (i.e. outside an implementer
# environment), and fails open in every case: this hook must never block a
# session from starting.
set -uo pipefail

[ -n "${FACTORY_BROKER_URL:-}" ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0
command -v gh >/dev/null 2>&1 || exit 0

root="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
helper="$root/scripts/factory-token"
[ -x "$helper" ] || exit 0

# `shim` prints the `export PATH=…` line to stdout and its notes to stderr.
# A failure here (no broker, no repo, proxy-injected mode) is not fatal: the
# session starts without the shim and the unwrapped gh calls fail closed.
if line=$("$helper" shim 2>/dev/null); then
	printf '%s\n' "$line" >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
	printf 'factory-token: gh shim installed for this session (spec 2d).\n'
else
	printf 'factory-token: gh shim not installed (the helper could not mint a token). Unwrapped gh calls will fail on the pass-through sentinel; run "%s" status to see why.\n' "$helper" >&2
fi
exit 0
