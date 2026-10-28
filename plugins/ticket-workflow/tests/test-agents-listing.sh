#!/usr/bin/env bash
# Tests for the session lookup in the spawn skill's backends/local.md (*Find
# and resume before you spawn*) and its copy in EPIC Step 5's worked example.
# They run the documented snippets, pulled out of the docs, against a claude
# stub that serves a fixture listing shaped like Claude Code 2.1.312's
# `claude agents --json --all`, so the docs can't drift from what is tested:
#
# - the lifecycle is `state`, not `status`: each match's `class` comes from
#   its `state` alone, so a `stopped` row, which has no `status`, is
#   resumable (#275), `working` and `blocked` rows are running whatever their
#   `status`, and a row with another `state`, or none, is unplaced;
# - only rows launched from the launch dir match, and a prefix ending at its
#   delimiter doesn't also match a longer ID (`#26: ` vs `#263: `);
# - matches sort oldest first, so the newest is last;
# - no doc decides by `status` or shows a lifecycle in it.
#
# Runs the snippets under bash, and under zsh too when it's installed (the
# Bash tool runs zsh). Needs jq.
#
#   bash plugins/ticket-workflow/tests/test-agents-listing.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
spawn_plugin=$(cd "$plugin/../spawn" && pwd)
local_md="$spawn_plugin/skills/spawn/backends/local.md"
epic_md="$plugin/skills/ticket-workflow/phases/epic.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

lookup=$(extract_block "$local_md" 'claude agents --json --all > "$agents"' |
	sed -e 's/<prefix>/widgets #26: /' -e 's/<alternate prefix>/widgets 26: /')
record yes "lookup snippet found in local.md" "$([ -n "$lookup" ] && echo yes || echo no)"

# EPIC Step 5's worked example, up to the end of its lookup (the rest reads a
# transcript and resumes).
epic_lookup=$(extract_block "$epic_md" 'claude agents --json --all > "$agents"' |
	awk '{ print } /sort_by\(\.startedAt\)'\'' "\$agents"/ { exit }')
record yes "lookup snippet found in epic.md" "$([ -n "$epic_lookup" ] && echo yes || echo no)"

# The stub answers only the listing the snippets run.
mkdir "$tmp/bin"
cat >"$tmp/bin/claude" <<'STUB_EOF'
#!/usr/bin/env bash
[ "$*" = "agents --json --all" ] || { echo "unexpected claude call: $*" >&2; exit 1; }
cat "$STUB_DIR/agents.json"
STUB_EOF
chmod +x "$tmp/bin/claude"
export STUB_DIR="$tmp"

# One row per (state, status) pair seen on 2.1.312, plus rows the lookup must
# leave out or can't place. Built with jq so a missing field is really missing.
row() { # row <name> <state|-> <status|-> <startedAt> [cwd]
	jq -nc --arg n "$1" --arg st "$2" --arg su "$3" --arg t "$4" --arg c "${5:-/home/me/widgets}" '
		{id: "a1b2c3d4", cwd: $c, kind: "background", name: $n,
		 sessionId: "5f0c2a9e-3b1d-4c7a-9e21-6d8f0b4a7c13", startedAt: $t}
		+ (if $st == "-" then {} else {state: $st} end)
		+ (if $su == "-" then {} else {status: $su} end)'
}
{
	row "widgets #26: stopped" stopped - 2026-10-27T10:00:00Z
	row "widgets #26: done idle" done idle 2026-10-27T10:01:00Z
	row "widgets #26: done" done - 2026-10-27T10:02:00Z
	row "widgets #26: working busy" working busy 2026-10-27T10:03:00Z
	row "widgets 26: working idle" working idle 2026-10-27T10:04:00Z
	row "widgets #26: blocked busy" blocked busy 2026-10-27T10:05:00Z
	row "widgets #26: blocked idle" blocked idle 2026-10-27T10:06:00Z
	row "widgets #26: blocked waiting" blocked waiting 2026-10-27T10:07:00Z
	row "widgets #26: blocked" blocked - 2026-10-27T10:08:00Z
	row "widgets #26: failed" failed - 2026-10-27T10:09:00Z
	row "widgets #26: no state" - - 2026-10-27T10:10:00Z
	row "widgets #26: status only" - stopped 2026-10-27T10:11:00Z
	row "widgets #263: decoy" stopped - 2026-10-27T10:12:00Z
	row "widgets #26: other clone" stopped - 2026-10-27T10:13:00Z /home/me/elsewhere/widgets
	row "toolbox #263: add retry backoff" stopped - 2026-10-27T10:14:00Z /home/me/toolbox
	row "toolbox #263: older" done idle 2026-10-27T09:00:00Z /home/me/toolbox
} | jq -s . >"$tmp/agents.json"

# Runs a snippet with the stub first on PATH, and prints each match as
# <name>=<class>, oldest first, separated by |.
classes() { # classes <shell> <launch dir> <snippet>
	PATH="$tmp/bin:$PATH" TMPDIR="$tmp" launch_dir=$2 "$1" -c "$3" 2>/dev/null |
		jq -r 'map("\(.name)=\(.class)") | join("|")'
}

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)

for sh in "${shells[@]}"; do
	got=$(classes "$sh" /home/me/widgets "$lookup")
	record "widgets #26: stopped=resumable|widgets #26: done idle=resumable|widgets #26: done=resumable|widgets #26: working busy=running|widgets 26: working idle=running|widgets #26: blocked busy=running|widgets #26: blocked idle=running|widgets #26: blocked waiting=running|widgets #26: blocked=running|widgets #26: failed=unplaced|widgets #26: no state=unplaced|widgets #26: status only=unplaced" \
		"$sh: local.md classes every match by state, oldest first" "$got"

	stopped=$(printf '%s' "$got" | tr '|' '\n' | grep -c '^widgets #26: stopped=resumable$')
	record 1 "$sh: a stopped row with no status is resumable (#275)" "$stopped"

	got=$(classes "$sh" /home/me/toolbox "$epic_lookup")
	record "toolbox #263: older=resumable|toolbox #263: add retry backoff=resumable" \
		"$sh: epic.md's worked example classes the stopped child resumable" "$got"
done

# The worked example's sample output matches what its lookup prints.
record 1 "epic.md's sample row shows state and class, not status" \
	"$(grep -c '"state": "stopped", "class": "resumable"' "$epic_md")"

# No doc decides by status, or shows a lifecycle value in it.
stale=$(grep -rnE 'decide by `status`|"status": "(stopped|done|busy|blocked)"|a status you can.t place' \
	"$spawn_plugin/skills" "$plugin/skills" "$plugin/commands" 2>/dev/null | wc -l | tr -d ' ')
record 0 "no doc keys the lookup on status" "$stale"

finish
