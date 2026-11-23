#!/usr/bin/env bash
# Tests for the session-link read in the spawn skill's backends/local.md
# (*Session links*), which SPAWN Step 4, EPIC Step 5 and /spawn-epic point at.
# They run the documented snippet, pulled out of the doc, against fixture job
# directories shaped like Claude Code 2.1.326's ~/.claude/jobs/<id>/state.json,
# so the doc can't drift from what is tested:
#
# - a plain `cse_<x>` bridgeSessionId becomes https://claude.ai/code/session_<x>;
# - anything else (no file, no field, null, a number, a value that isn't
#   exactly `cse_` and letters and digits, a file that isn't JSON) prints `-`,
#   so the report keeps the plain name and never a guessed or injected link;
# - the jobs directory is under CLAUDE_CONFIG_DIR, else $HOME/.claude;
# - every doc that reports a session points at the one rule.
#
# Runs the snippet under bash, and under zsh too when it's installed (the Bash
# tool runs zsh). Needs jq.
#
#   bash plugins/ticket-workflow/tests/test-session-links.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
spawn_plugin=$(cd "$plugin/../spawn" && pwd)
local_md="$spawn_plugin/skills/spawn/backends/local.md"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

ids="a0000001 a0000002 a0000003 a0000004 a0000005 a0000006 a0000007 a0000008 a0000009 a0000010"
snippet=$(extract_block "$local_md" '.bridgeSessionId' | sed "s/<short id> <short id>/$ids/")
record yes "link snippet found in local.md" "$([ -n "$snippet" ] && echo yes || echo no)"
record 0 "the snippet's placeholder was filled" "$(printf '%s' "$snippet" | grep -c '<short id>')"

# One job per case. a0000004 has no directory at all.
job() { # job <config dir> <id> <state.json text>
	mkdir -p "$1/jobs/$2" && printf '%s\n' "$3" >"$1/jobs/$2/state.json"
}
fixtures() { # fixtures <config dir>
	job "$1" a0000001 '{"bridgeSessionId": "cse_01ABCDEFGHJKMNPQRSTVWXYZ", "bridgeOutboundOnly": false, "state": "working"}'
	job "$1" a0000002 '{"bridgeSessionId": null, "bridgeOutboundOnly": null, "state": "done"}'
	job "$1" a0000003 '{"state": "done"}'
	job "$1" a0000005 '{"bridgeSessionId": "cse_abc\n"}'
	job "$1" a0000006 '{"bridgeSessionId": "session_01ABCDEFGHJKMNPQRSTVWXYZ"}'
	job "$1" a0000007 '{"bridgeSessionId": 12}'
	job "$1" a0000008 'not json'
	job "$1" a0000009 '{"bridgeSessionId": "cse_ab](https://example.com/x"}'
	job "$1" a0000010 '{"bridgeSessionId": "cse_"}'
}
fixtures "$tmp/config"
fixtures "$tmp/home/.claude"

expected=$(printf '%s\t%s\n' \
	a0000001 https://claude.ai/code/session_01ABCDEFGHJKMNPQRSTVWXYZ \
	a0000002 - a0000003 - a0000004 - a0000005 - a0000006 - a0000007 - \
	a0000008 - a0000009 - a0000010 -)

shells=(bash)
command -v zsh >/dev/null 2>&1 && shells+=(zsh)

# zsh runs with -f, so a ~/.zshenv that sets CLAUDE_CONFIG_DIR can't undo
# the environment each case sets up.
run() { # run <shell> <script>
	if [ "$1" = zsh ]; then zsh -f -c "$2"; else "$1" -c "$2"; fi
}
for sh in "${shells[@]}"; do
	got=$(CLAUDE_CONFIG_DIR="$tmp/config" run "$sh" "$snippet" 2>&1)
	record "$expected" "$sh: CLAUDE_CONFIG_DIR's jobs: one link, a dash for every other case" "$got"

	got=$(unset CLAUDE_CONFIG_DIR; HOME="$tmp/home" run "$sh" "$snippet" 2>&1)
	record "$expected" "$sh: with no CLAUDE_CONFIG_DIR, \$HOME/.claude's jobs" "$got"

	got=$(CLAUDE_CONFIG_DIR="$tmp/nowhere" run "$sh" "$snippet" 2>&1 | cut -f2 | sort -u)
	record "-" "$sh: no jobs directory at all prints only dashes" "$got"
done

# The cloud backend builds its link from the id create_session returned. Run
# the id pattern cloud.md gives (its one backticked ^session_ pattern) against
# the shapes it must accept and refuse, each id matched as one string, as the
# doc says.
cloud_md="$spawn_plugin/skills/spawn/backends/cloud.md"
pattern=$(grep -o '`\^session_[^`]*`' "$cloud_md" | tr -d '`')
record 1 "cloud.md gives one session_ id pattern" "$(printf '%s\n' "$pattern" | grep -c .)"
accepts() { if [[ $1 =~ $pattern ]]; then echo 1; else echo 0; fi; }
record 1 "cloud.md's pattern accepts a plain session_ id" "$(accepts session_01ABCDEFGHJKMNPQRSTVWXYZ)"
for bad in cse_01ABCDEFGHJKMNPQRSTVWXYZ 'session_01AB](https://example.com/x' 'session_01AB?x=1' \
	session_ '' $'session_01AB\nx' $'x\nsession_01AB' $'session_01AB\n'; do
	record 0 "cloud.md's pattern refuses '$bad'" "$(accepts "$bad")"
done

# The spawn skill holds the one rule: step 5, and each backend's *Session
# links*. The ticket-workflow docs that report sessions point at it by name
# and don't restate the read.
repo=$(cd "$plugin/../.." && pwd)
for f in "$spawn_plugin/skills/spawn/backends/local.md" "$cloud_md"; do
	record 1 "${f#"$repo/"} has a *Session links*" \
		"$(grep -cE '^(## Session links$|\*\*Session links\.\*\*)' "$f")"
done
for f in "$plugin/skills/ticket-workflow/phases/spawn.md" \
	"$plugin/skills/ticket-workflow/phases/epic.md" \
	"$plugin/skills/spawn-epic/SKILL.md"; do
	record yes "${f#"$repo/"} points at the spawn skill's step 5 and *Session links*" \
		"$(grep 'Session links' "$f" | grep -q "the \`spawn\` skill's step 5" && echo yes || echo no)"
	record 0 "${f#"$repo/"} doesn't restate the read" "$(grep -c 'bridgeSessionId\|state\.json' "$f")"
done

finish
