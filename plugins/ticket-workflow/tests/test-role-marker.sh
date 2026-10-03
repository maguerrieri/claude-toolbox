#!/usr/bin/env bash
# Tests for scripts/role-marker.sh, which makes every role-marker read and
# write the docs describe: each subcommand, the session-id lookup, appending to
# a marker with no trailing newline, atomic writes, the notify name checks, and
# the one-liners the docs show, run as written. The script runs under the bash
# running this file, so `/bin/bash tests/test-role-marker.sh` checks it under
# macOS's bash 3.2. Needs jq for the session-start round trip.
#
#   bash plugins/ticket-workflow/tests/test-role-marker.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/role-marker.sh"
skill="$plugin/skills/ticket-workflow"
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
roles_dir="$tmp/roles"
sid=test-session
. "$here/lib.sh"

# The marker as one line, newlines as |, or none.
marker() { # marker [id]
	if [ -f "$roles_dir/${1:-$sid}" ]; then tr '\n' '|' <"$roles_dir/${1:-$sid}"; else printf none; fi
}

# Starts from <initial> as this session's marker (none: no marker, and no
# roles directory either), runs the script with <stdin> and the arguments
# under a clean environment, and prints the marker afterwards and the exit
# status. stdout and stderr are kept in $tmp/out and $tmp/err.
run() { # run <initial | none> <stdin> <arg> ...
	rm -rf "${roles_dir:?}"
	if [ "$1" != none ]; then
		mkdir -p "$roles_dir"
		printf '%s' "$1" >"$roles_dir/$sid"
	fi
	printf '%s' "$2" | env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_ROLES_DIR="$roles_dir" \
		CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" "${@:3}" >"$tmp/out" 2>"$tmp/err"
	local status=$?
	printf '%s exit %s' "$(marker)" "$status"
}

# --- show --------------------------------------------------------------------

record "none exit 0" "show: no marker" "$(run none '' show)"
record "" "show: no marker prints nothing" "$(cat "$tmp/out")"
record 1 "show: no marker says so on stderr" "$(grep -c 'no role marker' "$tmp/err")"
record "implementer|issue: 52|notify: repo x| exit 0" "show: leaves the marker alone" \
	"$(run $'implementer\nissue: 52\nnotify: repo x\n' '' show)"
record $'implementer\nissue: 52\nnotify: repo x' "show: prints the marker" "$(cat "$tmp/out")"
run implementer '' show >/dev/null
record "1 implementer" "show: a marker without a trailing newline prints one line" \
	"$(wc -l <"$tmp/out" | tr -d ' ') $(cat "$tmp/out")"
record "none exit 1" "show: an extra argument" "$(run none '' show x)"

# --- pin ---------------------------------------------------------------------

record "implementer|issue: 52| exit 0" "pin: new marker, issue recorded" "$(run none '' pin implementer --issue 52)"
record "implementer|issue: 52| exit 0" "pin: a leading # is stripped" "$(run none '' pin implementer --issue '#52')"
record "implementer|issue: ABC-12| exit 0" "pin: a Jira key" "$(run none '' pin implementer --issue ABC-12)"
record "planner| exit 0" "pin: role only" "$(run none '' pin planner)"
record "implementer|issue: 7|notify: repo x| exit 0" "pin: the same role keeps the marker" \
	"$(run $'implementer\nissue: 7\nnotify: repo x\n' '' pin implementer)"
record "implementer|issue: 7|issue: 52| exit 0" "pin: a second issue is appended" \
	"$(run $'implementer\nissue: 7\n' '' pin implementer --issue 52)"
record "implementer|issue: 52|notify: x| exit 0" "pin: a recorded issue isn't repeated" \
	"$(run $'implementer\nissue: 52\nnotify: x\n' '' pin implementer --issue 52)"
record "implementer|issue: 5|issue: 52| exit 0" "pin: issue lines match whole" \
	"$(run $'implementer\nissue: 5\n' '' pin implementer --issue 52)"
record " implementer |issue: 52| exit 0" "pin: the role compares with whitespace stripped" \
	"$(run $' implementer \n' '' pin implementer --issue 52)"
record "epic-coordinator| exit 0" "pin: another role replaces the marker" \
	"$(run $'implementer\nissue: 52\nnotify: repo x\n' '' pin epic-coordinator)"
record "implementer|issue: 52| exit 0" "pin: marker without a trailing newline, issue appended on its own line" \
	"$(run implementer '' pin implementer --issue 52)"
record "implementer|issue: 7|issue: 52| exit 0" "pin: issue line without a trailing newline" \
	"$(run $'implementer\nissue: 7' '' pin implementer --issue 52)"
record "planner|issue: 52| exit 0" "pin: an unchanged marker is left as it is" \
	"$(run $'planner\nissue: 52\n' '' pin planner)"

# A bad role or a malformed command line: nothing is written, and the reason
# is on stderr.
for args in 'bogus' 'implementerx' 'none' 'implementer --task 52' 'implementer --issue 52 extra'; do
	# shellcheck disable=SC2086 # split the case into arguments
	record "planner| exit 1" "pin: refuses '$args'" "$(run $'planner\n' '' pin $args)"
	record 1 "pin: says why for '$args'" "$(grep -c 'nothing written' "$tmp/err")"
done
record "none exit 1" "pin: no role" "$(run none '' pin)"

# A bad --issue still pins the role: only the issue line is skipped, and
# stderr says so. (`--issue` with no value is what an unquoted `--issue #52`
# turns into, since the shell reads `#52` as a comment.)
for args in 'implementer --issue' 'implementer --issue 52;touch' 'implementer --issue $(x)' \
	'implementer --issue https://x/52' 'implementer --issue -5' 'implementer --issue #' \
	'implementer --issue 5.2' "implementer --issue $(printf '%065d' 0)"; do
	# shellcheck disable=SC2086 # split the case into arguments
	record "implementer| exit 0" "pin: '$args' pins the role alone" "$(run $'planner\n' '' pin $args)"
	record 1 "pin: says why for '$args'" "$(grep -c 'recorded no issue' "$tmp/err")"
done
record "epic-coordinator| exit 0" "pin: another role's --issue is skipped" "$(run none '' pin epic-coordinator --issue 5)"
record 1 "pin: says only an implementer records one" "$(grep -c 'only an implementer' "$tmp/err")"
record "implementer|issue: 7| exit 0" "pin: a bad --issue keeps the recorded ones" \
	"$(run $'implementer\nissue: 7\n' '' pin implementer --issue 'x y')"
record "implementer|issue: $(printf '%064d' 0)| exit 0" "pin: a 64-character issue id" \
	"$(run none '' pin implementer --issue "$(printf '%064d' 0)")"
record "implementer|issue: ABC-12| exit 0" "pin: a recorded Jira key matches in any case" \
	"$(run $'implementer\nissue: ABC-12\n' '' pin implementer --issue abc-12)"

# --- unpin -------------------------------------------------------------------

record "none exit 0" "unpin: deletes the marker" "$(run $'implementer\nissue: 52\nnotify: x\n' '' unpin)"
record "none exit 0" "unpin: no marker is fine" "$(run none '' unpin)"
record "planner| exit 1" "unpin: an extra argument" "$(run $'planner\n' '' unpin now)"

# --- notify ------------------------------------------------------------------

em_200="$(printf '%0197d' 0)—" # 197 + 3 bytes: 200 whatever the locale
tricky="widgets #40: epic — user's \"auth\" & CI [ad63a1] \$(touch $tmp/pwned)"
record "implementer|issue: 52|notify: repo #52: new| exit 0" "notify: replaces the old line" \
	"$(run $'implementer\nissue: 52\nnotify: old\n' $'repo #52: new\n' notify)"
record "epic-coordinator|notify: planning| exit 0" "notify: marker without a trailing newline" \
	"$(run epic-coordinator planning notify)"
record "implementer|notify: $tricky| exit 0" "notify: quotes and shell syntax stay data" \
	"$(run $'implementer\n' "$tricky" notify)"
record absent "notify: nothing in the name ran" "$([ -e "$tmp/pwned" ] && echo present || echo absent)"
record "implementer|notify: repo planning| exit 0" "notify: surrounding whitespace trimmed" \
	"$(run $'implementer\n' $'  repo planning \t\n' notify)"
record "implementer|notify: second| exit 0" "notify: only the first line is the name" \
	"$(run $'implementer\n' $'second\nthird\n' notify)"
record "none exit 1" "notify: no marker, none created" "$(run none 'repo planning' notify)"
record 1 "notify: no marker says why" "$(grep -c 'no role marker' "$tmp/err")"
record "implementer|notify: old| exit 1" "notify: backtick rejected, marker untouched" \
	"$(run $'implementer\nnotify: old\n' 'x`id`' notify)"
record "implementer| exit 1" "notify: blank name rejected" "$(run $'implementer\n' '   ' notify)"
record "implementer| exit 1" "notify: no name" "$(run $'implementer\n' '' notify)"
record "implementer| exit 1" "notify: a tab inside the name" "$(run $'implementer\n' $'a\tb' notify)"
record "implementer| exit 1" "notify: a line separator (U+2028)" "$(run $'implementer\n' $'a\xe2\x80\xa8b' notify)"
record "implementer| exit 1" "notify: overlong name rejected" "$(run $'implementer\n' "$(printf '%0201d' 0)" notify)"
record "implementer| exit 1" "notify: over 200 bytes with an em dash" "$(run $'implementer\n' "0$em_200" notify)"
record "implementer|notify: $em_200| exit 0" "notify: 200 bytes with an em dash" "$(run $'implementer\n' "$em_200" notify)"
record "implementer| exit 1" "notify: an extra argument" "$(run $'implementer\n' x notify now)"

# The line it writes is the one role-session-start.sh re-injects.
run $'implementer\nissue: 52\n' "$tricky" notify >/dev/null
reinjected=$(jq -n --arg sid "$sid" '{session_id: $sid, source: "compact"}' |
	env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_PLUGIN_ROOT="$plugin" \
		"$BASH" "$plugin/hooks/role-session-start.sh")
record 1 "notify: the charter is re-injected" "$(printf '%s\n' "$reinjected" | grep -c '^This session is pinned to the \*\*implementer\*\* role charter')"
record "$tricky" "notify: the name is re-injected" \
	"$(printf '%s\n' "$reinjected" | sed -n 's/^Your `Notify:` target is `\(.*\)`: .*/\1/p')"

# --- The session id ----------------------------------------------------------

# Pins planner with the given variables, the marker named `parent` already
# holding implementer, and prints each marker as <name>=<content>.
pin_with() { # pin_with [VAR=value ...]
	rm -rf "${roles_dir:?}"
	mkdir -p "$roles_dir"
	printf 'implementer\n' >"$roles_dir/parent"
	env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_SESSION_ROLES_DIR="$roles_dir" "$@" "$BASH" "$script" pin planner 2>"$tmp/err"
	local status=$?
	for f in "$roles_dir"/*; do
		[ -f "$f" ] && printf '%s=%s ' "$(basename "$f")" "$(tr '\n' '|' <"$f")"
	done
	printf 'exit %s' "$status"
}
record "child=planner| parent=implementer| exit 0" "id: the harness's id wins over an inherited CLAUDE_SESSION_ID" \
	"$(pin_with CLAUDE_CODE_SESSION_ID=child CLAUDE_SESSION_ID=parent)"
record "child=planner| parent=implementer| exit 0" "id: CLAUDE_SESSION_ID when the harness sets none" \
	"$(pin_with CLAUDE_SESSION_ID=child)"
record "child=planner| parent=implementer| exit 0" "id: an empty harness id falls back" \
	"$(pin_with CLAUDE_CODE_SESSION_ID= CLAUDE_SESSION_ID=child)"
record "parent=implementer| exit 1" "id: none, nothing written" "$(pin_with)"
record 1 "id: none says why" "$(grep -c 'no session id' "$tmp/err")"
for bad in ../parent . 'a/b' 'a b' '..'; do
	record "parent=implementer| exit 1" "id: '$bad' is not a plain token" "$(pin_with CLAUDE_CODE_SESSION_ID="$bad")"
done
out=$(env -i PATH="$PATH" CLAUDE_CODE_SESSION_ID=s "$BASH" "$script" pin planner 2>&1)
record "1 1" "id: neither the override nor HOME" "$? $(printf '%s\n' "$out" | grep -c 'nor HOME')"
env -i PATH="$PATH" HOME="$tmp/home" CLAUDE_CODE_SESSION_ID=s "$BASH" "$script" pin planner
record "planner|" "id: the default directory under HOME" \
	"$(tr '\n' '|' <"$tmp/home/.claude/session-roles/s" 2>/dev/null)"

# --- Atomic writes -----------------------------------------------------------

# A write renames a new file over the marker rather than rewriting it in place:
# a hard link to the old marker keeps the old content.
run $'implementer\nissue: 7\n' '' show >/dev/null
ln "$roles_dir/$sid" "$tmp/old-marker"
env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" pin implementer --issue 52
record "implementer|issue: 7|" "atomic: the old marker is never rewritten" "$(tr '\n' '|' <"$tmp/old-marker")"
record "implementer|issue: 7|issue: 52|" "atomic: the new one replaces it" "$(marker)"
rm -f "$tmp/old-marker"
printf 'repo x\n' | env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" notify
record "$sid" "atomic: no temp file is left behind" "$(ls -A "$roles_dir" | tr '\n' ' ' | sed 's/ $//')"

# A write that can't land leaves the marker as it was, and no temp file.
# (Root ignores the permission this takes away, so skip it there.)
if [ "$(id -u)" != 0 ]; then
	run $'implementer\nissue: 7\n' '' show >/dev/null
	chmod a-w "$roles_dir"
	env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_CODE_SESSION_ID="$sid" "$BASH" "$script" pin planner 2>"$tmp/err"
	status=$?
	chmod u+w "$roles_dir"
	record "1 implementer|issue: 7|" "atomic: a failed write leaves the marker" "$status $(marker)"
	record "$sid" "atomic: a failed write leaves no temp file" "$(ls -A "$roles_dir" | tr '\n' ' ' | sed 's/ $//')"
fi

# --- The documented one-liners -----------------------------------------------

# Runs <command> as the docs give it, with the plugin root set (or not), and
# prints the marker afterwards and the exit status.
run_doc() { # run_doc <initial | none> <command> [plugin root]
	rm -rf "${roles_dir:?}"
	if [ "$1" != none ]; then
		mkdir -p "$roles_dir"
		printf '%s' "$1" >"$roles_dir/$sid"
	fi
	env -i PATH="$PATH" CLAUDE_SESSION_ROLES_DIR="$roles_dir" CLAUDE_CODE_SESSION_ID="$sid" \
		CLAUDE_TICKET_WORKFLOW_ROOT="${3-$plugin}" "$BASH" -c "$2" >"$tmp/out" 2>"$tmp/err"
	local status=$?
	printf '%s exit %s' "$(marker)" "$status"
}

self_pin=$(extract_block "$skill/SKILL.md" 'role-marker.sh" pin <role> --issue <id>' | sed -e 's/<role>/implementer/' -e 's/<id>/52/')
notify_doc=$(extract_block "$skill/SKILL.md" 'role-marker.sh" notify' | sed "s/^<session name>\$/repo planning/")
show_doc=$(extract_block "$skill/SKILL.md" 'role-marker.sh" show')
role_pin=$(extract_block "$plugin/commands/role.md" 'role-marker.sh" pin <role>' | sed 's/<role>/planner/')
role_unpin=$(extract_block "$plugin/commands/role.md" 'role-marker.sh" unpin')
for doc in self_pin notify_doc show_doc role_pin role_unpin; do
	record yes "doc one-liner $doc found" "$([ -n "${!doc}" ] && echo yes || echo no)"
done

record "implementer|issue: 52| exit 0" "doc: START's self-pin" "$(run_doc none "$self_pin")"
record "implementer|issue: 52|notify: repo planning| exit 0" "doc: START's notify record" \
	"$(run_doc $'implementer\nissue: 52\n' "$notify_doc")"
record "implementer|issue: 52| exit 0" "doc: the spawn guard's read" "$(run_doc $'implementer\nissue: 52\n' "$show_doc")"
record implementer "doc: the read's first line is the role" "$(head -n 1 "$tmp/out")"
record "planner| exit 0" "doc: /role <role>" "$(run_doc $'implementer\nissue: 52\n' "$role_pin")"
record "none exit 0" "doc: /role none" "$(run_doc $'planner\n' "$role_unpin")"

# With the plugin root unset, each stops before running anything, and says why.
# The status is the shell's (bash 127, zsh 1), so only its being non-zero counts.
nonzero() { # nonzero <run_doc output>: the marker, then ok or failed
	case "$1" in
	*' exit 0') printf '%s ok' "${1% exit *}" ;;
	*) printf '%s failed' "${1% exit *}" ;;
	esac
}
record "none failed" "doc: plugin root unset, the self-pin writes nothing" "$(nonzero "$(run_doc none "$self_pin" '')")"
record 1 "doc: plugin root unset says why" "$(grep -c 'CLAUDE_TICKET_WORKFLOW_ROOT' "$tmp/err")"
record "implementer| failed" "doc: plugin root unset, the notify record writes nothing" \
	"$(nonzero "$(run_doc $'implementer\n' "$notify_doc" '')")"

# A stale root (an older plugin version, kept side by side in the cache,
# without the script) fails the same way, naming the missing file.
mkdir -p "$tmp/old-version/scripts"
record "none failed" "doc: stale plugin root, the self-pin writes nothing" \
	"$(nonzero "$(run_doc none "$self_pin" "$tmp/old-version")")"
record 1 "doc: stale plugin root says why" "$(grep -c 'role-marker.sh: No such file' "$tmp/err")"
record "implementer|issue: 52| failed" "doc: stale plugin root, the read fails rather than printing nothing" \
	"$(nonzero "$(run_doc $'implementer\nissue: 52\n' "$show_doc" "$tmp/old-version")")"

finish
