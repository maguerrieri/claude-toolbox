#!/usr/bin/env bash
# ledger.sh — every read and write of a session's ledger that the docs
# describe. The ledger is one JSONL file per session under the ledger
# directory, one entry per line:
#
#   {"kind":"decision"|"need","id":"d1"|"n1","text":…,"ref":…,"at":…,"cwd":…,"resolved_at":…}
#
# `ref` (an issue or PR, optional) and `resolved_at` (needs only) may be
# absent. `at` and `resolved_at` are ISO-8601 UTC. `cwd` is where the session
# wrote from, so a reader can name a session `claude agents` doesn't list.
# The mod (hooks/register.tsx) reads the files directly; nothing but this
# script writes them.
#
#   ledger.sh add-decision [--ref <ref>] <<'LEDGER_EOF'   record a decision; prints its id
#   <text>
#   LEDGER_EOF
#   ledger.sh add-need [--ref <ref>] <<'LEDGER_EOF'       record a need; prints its id
#   <text>
#   LEDGER_EOF
#   ledger.sh resolve <need id> [--session <session>]     mark a need resolved
#   ledger.sh list [--all]                                this session's entries, or
#                                                         open needs across sessions
#
# The docs run it as `bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" …`; the
# plugin's SessionStart hook sets that variable.
#
# The text comes on stdin, from a quoted heredoc, so no character of it
# reaches a shell as syntax. One trailing newline is dropped; the rest is
# kept, lines included. Empty or whitespace-only text, text over 4000 bytes,
# and control characters other than tab and newline are refused. A ref is
# letters, digits and # / _ . : -, starting with a letter, digit or #, at most
# 100 bytes (#212, owner/repo#12, ABC-12).
#
# A session writes only its own ledger, keyed by its session id: the harness's
# CLAUDE_CODE_SESSION_ID, else the CLAUDE_SESSION_ID that ticket-workflow's
# SessionStart hook exports on older CLIs. The one exception is
# `resolve --session` (the full id, or a unique prefix of at least four
# characters): the owner dismissing another session's need, or a FINISH that
# landed another session's PR resolving its hand-back.
#
# `list` prints this session's open needs, decisions and resolved needs,
# newest first. `list --all` prints the open needs of every session's ledger,
# newest first, then this session's decisions. Another session is shown as
# `<name> (<short id>)`: its name where `claude agents --json --all` lists it,
# else the directory it wrote from. The short id, the session id's first eight
# characters, is `claude attach`'s handle and a `resolve --session` prefix.
#
# Every write goes to a temp file in the ledger directory and is renamed over
# the ledger, so a reader never sees half of one. Reads skip a line that isn't
# a JSON object. Exits 0 on success; exits 1 with the reason on stderr when
# nothing was written or read.
set -uo pipefail
# Bytes, not characters: the 4000-byte limit and the control-character check
# count bytes.
export LC_ALL=C

cmd=${1:-}

fail() {
	case "$cmd" in
	add-decision | add-need | resolve) printf 'ledger %s: %s; nothing written\n' "$cmd" "$1" >&2 ;;
	*) printf 'ledger %s: %s\n' "${cmd:-(no subcommand)}" "$1" >&2 ;;
	esac
	exit 1
}

usage='usage: ledger.sh add-decision|add-need [--ref <ref>] (text on stdin) | resolve <need id> [--session <session>] | list [--all]'

command -v jq >/dev/null 2>&1 || fail 'jq is required'

# id_ok <id> succeeds when <id> is a plain token that may name a ledger file:
# no path separator, no dot-dot, not just a dot (the role marker's rule).
id_ok() {
	case "$1" in
	'' | . | *[!A-Za-z0-9._-]* | *..*) return 1 ;;
	esac
}

# Check every argument before touching anything.
ref='' has_ref=no text='' need='' session='' all=no
case "$cmd" in
add-decision | add-need)
	shift
	while [ $# -gt 0 ]; do
		case "$1" in
		--ref)
			[ $# -ge 2 ] || fail "$usage"
			ref=$2 has_ref=yes
			shift 2
			;;
		*) fail "$usage" ;;
		esac
	done
	if [ "$has_ref" = yes ]; then
		case "$ref" in
		'' | [!A-Za-z0-9#]* | *[!A-Za-z0-9#/_.:-]*) fail 'the ref is empty or not just letters, digits and # / _ . : - (#212, owner/repo#12, ABC-12)' ;;
		esac
		[ "${#ref}" -le 100 ] || fail 'the ref is over 100 bytes'
	fi
	# The text comes from a heredoc; from a terminal, reading would only block.
	[ ! -t 0 ] || fail "$usage"
	# All of stdin, kept exact (the x stops $(...) from stripping trailing
	# newlines), less one trailing newline.
	text=$(
		cat
		printf x
	)
	text=${text%x}
	text=${text%$'\n'}
	case "$text" in
	*[![:space:]]*) ;;
	*) fail 'the text is empty' ;;
	esac
	[ "${#text}" -le 4000 ] || fail 'the text is over 4000 bytes'
	[ "$(printf '%s' "$text" | tr -d '\001-\010\013-\037\177' | wc -c)" -eq "${#text}" ] ||
		fail 'the text has a control character (only tab and newline are kept)'
	;;
resolve)
	shift
	[ $# -ge 1 ] || fail "$usage"
	need=$1
	shift
	case "$need" in
	n[1-9]*) ;;
	*) fail "'$need' is not a need id (n1, n2, …)" ;;
	esac
	case "${need#n}" in
	*[!0-9]*) fail "'$need' is not a need id (n1, n2, …)" ;;
	esac
	[ "${#need}" -le 10 ] || fail "'$need' is not a need id (n1, n2, …)"
	if [ $# -gt 0 ]; then
		[ "$1" = --session ] && [ $# -eq 2 ] || fail "$usage"
		session=$2
		id_ok "$session" || fail 'the session is not a plain token'
		[ "${#session}" -ge 4 ] || fail 'the session prefix is under four characters'
	fi
	;;
list)
	[ $# -le 2 ] || fail "$usage"
	case "${2-}" in
	'') ;;
	--all) all=yes ;;
	*) fail "$usage" ;;
	esac
	;;
*) fail "$usage" ;;
esac

sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [ -n "$sid" ]; then
	id_ok "$sid" || fail 'the session id is not a plain token'
elif [ "$all" = no ] && [ -z "$session" ]; then
	# Only list --all, and a resolve that names its session, need no id.
	fail 'no session id (neither CLAUDE_CODE_SESSION_ID nor CLAUDE_SESSION_ID is set)'
fi
[ -n "${CLAUDE_SESSION_LEDGER_DIR:-}${HOME:-}" ] || fail 'neither CLAUDE_SESSION_LEDGER_DIR nor HOME is set'
dir="${CLAUDE_SESSION_LEDGER_DIR:-$HOME/.claude/session-ledger}"
file="$dir/$sid.jsonl"

# entries <file>: the file's entries, one compact JSON object per line,
# skipping any line that isn't one.
entries() {
	jq -cR 'fromjson? // empty | select(type == "object")' "$1"
}

# replace <file> <command…>: the command's stdout, through a temp file beside
# <file> and a rename over it.
replace() {
	local target=$1 tmp base
	shift
	base=${target##*/}
	mkdir -p "$dir" 2>/dev/null || fail 'the ledger directory could not be created'
	tmp=$(mktemp "$dir/.$base.XXXXXX" 2>/dev/null) || fail 'no temp file could be created in the ledger directory'
	if "$@" >"$tmp" && mv -f "$tmp" "$target"; then
		return 0
	fi
	rm -f "$tmp"
	fail 'the ledger could not be written'
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The jq helpers both listings use: a date in local time, an entry's heading
# line and its indented text, control characters shown as ? (a hand-edited
# file may hold one), and newest-first order.
jq_defs='
def clean: gsub("[\\x01-\\x08\\x0b-\\x1f\\x7f]"; "?");
def when: (.at | (fromdateiso8601? // null)) as $t
	| if $t == null then "?" else ($t | strflocaltime("%Y-%m-%d %H:%M")) end;
def num: (.id[1:] | tonumber? // 0);
def heading($label): ($label + [.id, when] + (if (.ref | type) == "string" then [.ref] else [] end))
	| map(clean) | join(" · ");
def body: (.text | tostring | split("\n") | map("    " + clean) | join("\n"));
def show($label): "  " + heading($label) + "\n" + body;
def section($title; $label): if length == 0 then empty
	else ($title + " (\(length)):"), (.[] | show($label)) end;
'

# append_entry <kind> <letter>: the ledger with one more entry of <kind>,
# numbered after the highest id of that kind it holds.
append_entry() {
	if [ -f "$file" ]; then
		cat "$file" || return 1
		# A ledger without a trailing newline still gets the entry on its own line.
		[ -z "$(tail -c 1 "$file")" ] || echo
	fi
	printf '%s\n' "$entry"
}

case "$cmd" in
add-decision | add-need)
	kind=${cmd#add-}
	letter=${kind:0:1}
	last=0
	if [ -f "$file" ]; then
		last=$(entries "$file" | jq -s --arg k "$kind" '[.[] | select(.kind == $k) | (.id[1:] | tonumber? // 0)] | max // 0') ||
			fail 'the ledger could not be read'
	fi
	id="$letter$((last + 1))"
	entry=$(jq -cn --arg kind "$kind" --arg id "$id" --arg text "$text" --arg ref "$ref" \
		--arg at "$now" --arg cwd "$PWD" \
		'{kind: $kind, id: $id, text: $text} + (if $ref == "" then {} else {ref: $ref} end) + {at: $at, cwd: $cwd}') ||
		fail 'the entry could not be built'
	replace "$file" append_entry
	printf '%s\n' "$id"
	;;
resolve)
	if [ -n "$session" ]; then
		if [ -f "$dir/$session.jsonl" ]; then
			file="$dir/$session.jsonl"
		else
			shopt -s nullglob
			matches=("$dir/$session"*.jsonl)
			shopt -u nullglob
			[ "${#matches[@]}" -gt 0 ] || fail "no session's ledger starts with '$session'"
			[ "${#matches[@]}" -eq 1 ] || fail "more than one session's ledger starts with '$session'"
			file=${matches[0]}
		fi
	fi
	[ -f "$file" ] || fail 'this session has no ledger'
	state=$(entries "$file" | jq -rs --arg id "$need" \
		'[.[] | select(.kind == "need" and .id == $id)] | if length == 0 then "missing" elif any(.[]; .resolved_at == null) then "open" else "resolved" end') ||
		fail 'the ledger could not be read'
	case "$state" in
	missing) fail "the ledger has no need $need" ;;
	resolved)
		printf 'ledger resolve: %s is already resolved\n' "$need" >&2
		exit 0
		;;
	esac
	# Lines that aren't entries are kept as they are.
	replace "$file" jq -rR --arg id "$need" --arg at "$now" \
		'(fromjson? // null) as $e
		| if ($e | type) == "object" and $e.kind == "need" and $e.id == $id and $e.resolved_at == null
		  then $e + {resolved_at: $at} | tojson else . end' "$file"
	;;
list)
	if [ "$all" = no ]; then
		if [ ! -f "$file" ]; then
			echo "This session's ledger has no entries."
			exit 0
		fi
		entries "$file" | jq -rs "$jq_defs"'
			sort_by(.at, num) | reverse
			| if length == 0 then "This session'"'"'s ledger has no entries." else
				([.[] | select(.kind == "need" and .resolved_at == null)] | section("Open needs"; [])),
				([.[] | select(.kind == "decision")] | section("Decisions"; [])),
				([.[] | select(.kind == "need" and .resolved_at != null)] | section("Resolved needs"; []))
			  end' || fail 'the ledger could not be read'
		exit 0
	fi
	# Session names, where `claude agents` lists the session.
	names='{}'
	if command -v claude >/dev/null 2>&1; then
		listed=$(claude agents --json --all 2>/dev/null |
			jq -c 'if type == "array" then map(select(.sessionId and .name) | {key: .sessionId, value: .name}) | from_entries else empty end' 2>/dev/null) &&
			[ -n "$listed" ] && names=$listed
	fi
	shopt -s nullglob
	files=("$dir"/*.jsonl)
	shopt -u nullglob
	for ledger in ${files[@]+"${files[@]}"}; do
		owner=${ledger##*/}
		owner=${owner%.jsonl}
		id_ok "$owner" || continue
		entries "$ledger" | jq -c --arg s "$owner" '. + {session: $s}'
	done | jq -rs --argjson names "$names" --arg me "$sid" "$jq_defs"'
		def who: if .session == $me then "this session"
			elif ($names[.session] | type) == "string" then $names[.session] + " (" + .session[0:8] + ")"
			else ((.cwd // "" | tostring | split("/") | map(select(. != "")) | last) // "?") + " (" + .session[0:8] + ")" end;
		([.[] | select(.kind == "need" and .resolved_at == null)] | sort_by(.at, .session, num) | reverse) as $needs
		| ([.[] | select(.kind == "decision" and $me != "" and .session == $me)] | sort_by(.at, num) | reverse) as $decisions
		| if ($needs | length) == 0 then "No session has an open need."
		  else ("Open needs across sessions (\($needs | length)):"), ($needs[] | show([who])) end,
		  ($decisions | section("Decisions in this session"; []))' || fail 'the ledgers could not be read'
	;;
esac
