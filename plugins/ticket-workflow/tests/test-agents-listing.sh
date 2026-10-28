#!/usr/bin/env bash
# Tests for the session lookup in the spawn skill's backends/local.md (*Find
# and resume before you spawn*) and its copy in EPIC Step 5's worked example.
# They run the documented snippets, pulled out of the docs, against a claude
# stub that serves a fixture listing shaped like Claude Code 2.1.312's
# `claude agents --json --all`, so the docs can't drift from what is tested:
#
# - a row is running exactly when it has a `pid` (2.1.312 lists a `pid` and a
#   `status` only while the process lives), whatever its `state`, so a `done`
#   row idle after its turn is running too;
# - a row with no process is resumable when its `state` is `stopped` (which
#   never has a `status`, #275), `done`, or `working` or `blocked` (a process
#   that died mid-turn or at a prompt), and unplaced otherwise (another
#   `state`, or none), never by `status`;
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

# One row per (state, status, pid) shape seen on 2.1.312 (a live row has a
# pid and a status, a dead one neither), plus rows the lookup must leave out
# or can't place. startedAt is epoch milliseconds, as there. Built with jq so
# a missing field is really missing.
row() { # row <name> <state|-> <status|-> <pid|-> <startedAt minute> [cwd]
	jq -nc --arg n "$1" --arg st "$2" --arg su "$3" --arg p "$4" --argjson m "$5" \
		--arg c "${6:-/home/me/widgets}" '
		{id: "a1b2c3d4", cwd: $c, kind: "background", name: $n,
		 sessionId: "5f0c2a9e-3b1d-4c7a-9e21-6d8f0b4a7c13", startedAt: (1790380000000 + $m * 60000)}
		+ (if $st == "-" then {} else {state: $st} end)
		+ (if $su == "-" then {} else {status: $su} end)
		+ (if $p == "-" then {} else {pid: ($p | tonumber)} end)'
}
{
	row "widgets #26: stopped" stopped - - 0
	row "widgets #26: done" done - - 1
	row "widgets #26: done idle" done idle 4101 2
	row "widgets #26: working busy" working busy 4102 3
	row "widgets 26: working idle" working idle 4103 4
	row "widgets #26: blocked busy" blocked busy 4104 5
	row "widgets #26: blocked idle" blocked idle 4105 6
	row "widgets #26: blocked waiting" blocked waiting 4106 7
	row "widgets #26: blocked dead" blocked - - 8
	row "widgets #26: working dead" working - - 9
	row "widgets #26: failed" failed - - 10
	row "widgets #26: no state" - - - 11
	row "widgets #26: status only" - stopped - 12
	row "widgets #263: decoy" stopped - - 13
	row "widgets #26: other clone" stopped - - 14 /home/me/elsewhere/widgets
	row "toolbox #263: add retry backoff" stopped - - 15 /home/me/toolbox
	row "toolbox #263: older" done idle 4107 -60 /home/me/toolbox
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
	record "widgets #26: stopped=resumable|widgets #26: done=resumable|widgets #26: done idle=running|widgets #26: working busy=running|widgets 26: working idle=running|widgets #26: blocked busy=running|widgets #26: blocked idle=running|widgets #26: blocked waiting=running|widgets #26: blocked dead=resumable|widgets #26: working dead=resumable|widgets #26: failed=unplaced|widgets #26: no state=unplaced|widgets #26: status only=unplaced" \
		"$sh: local.md classes every match by pid and state, oldest first" "$got"

	stopped=$(printf '%s' "$got" | tr '|' '\n' | grep -c '^widgets #26: stopped=resumable$')
	record 1 "$sh: a stopped row with no status is resumable (#275)" "$stopped"

	got=$(classes "$sh" /home/me/toolbox "$epic_lookup")
	record "toolbox #263: older=running|toolbox #263: add retry backoff=resumable" \
		"$sh: epic.md's worked example classes the stopped child resumable" "$got"
done

# The worked example's sample output matches what its lookup prints.
record 1 "epic.md's sample row shows state and class, not status" \
	"$(grep -c '"state": "stopped", "class": "resumable"' "$epic_md")"

# No skill or command doc decides by status, or shows a lifecycle value in
# it (docs/ holds dated specs and plans, which keep their history).
stale=$(grep -rnE 'decide by `status`|\.status *[!=]=|select\(\.status|"status": "(stopped|done|working|blocked)"|status (is|of) `(stopped|done|working|blocked)`|a status you can.t place' \
	"$spawn_plugin/skills" "$spawn_plugin/commands" "$plugin/skills" "$plugin/commands" 2>/dev/null |
	grep -v 'session_status' | wc -l | tr -d ' ')
record 0 "no doc keys the lookup on status" "$stale"

# Nor on bare state names, which miss a live done row and a dead blocked one:
# a resume decision names the lookup's class.
stale=$(grep -rnE '`stopped` (or|/) `done`' \
	"$spawn_plugin/skills" "$spawn_plugin/commands" "$plugin/skills" "$plugin/commands" 2>/dev/null |
	wc -l | tr -d ' ')
record 0 "no doc decides a resume by stopped or done alone" "$stale"

finish
