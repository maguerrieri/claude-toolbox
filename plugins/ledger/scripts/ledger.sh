#!/usr/bin/env bash
# ledger.sh — every read and write of a session's ledger that the docs
# describe. The ledger is one JSONL file per session under the ledger
# directory, one entry per line:
#
#   {"kind":"decision"|"need","id":"d1"|"n1","why":…,"text":…,"ref":…,"at":…,"cwd":…,"resolved_at":…}
#
# `ref` (an issue or PR, optional) and `resolved_at` (needs only) may be
# absent, and so may `why` in an entry written before it existed. `why` is one
# short line of history and goal: why the work the entry is about exists, so
# the owner reading it days later remembers what it's for. `at` and
# `resolved_at` are ISO-8601 UTC. `cwd` is where the session wrote from, kept
# so a view across sessions (#316) can name a session `claude agents` doesn't
# list. Nothing but this script writes the files.
#
#   ledger.sh add-decision [--ref <ref>] <<'LEDGER_EOF'   record a decision; prints its id
#   Why: <history and goal>
#   <text>
#   LEDGER_EOF
#   ledger.sh add-need [--ref <ref>] <<'LEDGER_EOF'       record a need; prints its id
#   Why: <history and goal>
#   <text>
#   LEDGER_EOF
#   ledger.sh resolve <need id>                           mark a need resolved
#   ledger.sh resolve --ref <ref>                         resolve every open need with
#                                                         that ref; prints their ids
#   ledger.sh list                                        this session's entries
#
# The docs run it as `bash "${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh" …`; the
# plugin's SessionStart hook sets that variable.
#
# The text comes on stdin, from a quoted heredoc, so no character of it
# reaches a shell as syntax. Its first line must be `Why: <history and goal>`,
# at most 200 bytes after the prefix; it's stored as `why`, and the lines
# after it (less any blank lines leading them) as `text`. One trailing newline
# is dropped; the rest is kept, lines included. A missing or empty Why line,
# empty or whitespace-only text, text over 4000 bytes, control characters (C0,
# NUL included, and C1) other than tab and newline, and invisible formatting
# characters (bidi overrides and isolates, zero-width characters, line and
# paragraph separators, a byte-order mark) are refused, so nothing in an entry
# can make `list` read differently from what was recorded.
#
# Give a ref in full: <owner>/<repo>#<n>, a GitHub issue or PR URL (stored as
# <owner>/<repo>#<n>), or another tracker's key (ABC-12). A bare #<n> is a
# shorthand for an issue or PR of this checkout's own repo, written as
# <owner>/<repo>#<n> from the origin remote; outside a checkout of the ref's
# repo, or in a fork's (whose origin is the fork), it names the wrong repo, so
# pass the full ref there. An <owner>/<repo>#<n> is stored with its owner and
# repo lowercased, written or resolved. normalize_ref below has the exact
# rules.
#
# A session reads and writes only its own ledger, keyed by its session id: the
# harness's CLAUDE_CODE_SESSION_ID, else the CLAUDE_SESSION_ID this plugin's
# SessionStart hook exports on older CLIs. A need lives in the ledger of the
# session that needs the owner, and nobody copies it into another. (A view
# across every session's ledger, and the owner resolving another session's
# need, are #316.)
#
# `list` prints this session's open needs, decisions and resolved needs,
# newest first, each as its heading line, its Why line, then its text.
#
# Every write holds the ledger directory's lock (flock, through perl) from its
# read to its rename, goes to a temp file in the ledger directory, and is
# renamed over the ledger, so writes at once don't lose each other's entries
# and a reader never sees half of one.
# Reads skip a line that isn't an entry (an object with a string kind, id,
# text and at, and a string or null why, ref, cwd and resolved_at). Exits 0 on
# success; exits 1 with the reason on stderr when nothing was written or read.
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

usage='usage: ledger.sh add-decision|add-need [--ref <ref>] (Why line and text on stdin) | resolve <need id> | resolve --ref <ref> | list'

command -v jq >/dev/null 2>&1 || fail 'jq is required'
case "$cmd" in
add-decision | add-need | resolve) command -v perl >/dev/null 2>&1 || fail 'perl is required (it takes the write lock)' ;;
esac

# id_ok <id> succeeds when <id> is a plain token that may name a ledger file:
# no path separator, no dot-dot, not just a dot (the role marker's rule).
id_ok() {
	case "$1" in
	'' | . | *[!A-Za-z0-9._-]* | *..*) return 1 ;;
	esac
}

# normalize_ref: $ref in the form it's stored in, or fail. Accepted: a bare
# #<n> (an issue or PR of this checkout's repo, qualified from origin's URL:
# git@host:owner/repo.git, https://host/owner/repo, ssh://…), an
# <owner>/<repo>#<n>, a GitHub issue or PR URL (https://<host>/<owner>/<repo>/
# issues/<n> or /pull/<n>, anything after the number dropped), or another
# token (ABC-12, epic:40). A ref is then letters, digits and # / _ . : -,
# starting with a letter, digit or #, at most 200 bytes; at most one #, which
# must be followed by an issue or PR number. An <owner>/<repo>#<n> has its
# owner and repo lowercased, since GitHub ignores their case and origin's
# spelling of them can differ from a PR URL's.
normalize_ref() {
	local rest owner repo kind num url
	case "$ref" in
	[Hh][Tt][Tt][Pp]://* | [Hh][Tt][Tt][Pp][Ss]://*)
		rest=${ref#*://}
		rest=${rest#*/}
		owner=${rest%%/*}
		rest=${rest#*/}
		repo=${rest%%/*}
		rest=${rest#*/}
		kind=${rest%%/*}
		num=${rest#*/}
		num=${num%%[/?#]*}
		case "$kind" in
		issues | pull) ;;
		*) fail 'a URL ref must name an issue or PR (https://github.com/owner/repo/pull/12)' ;;
		esac
		case "$num" in
		'' | 0* | *[!0-9]*) fail 'a URL ref must name an issue or PR (https://github.com/owner/repo/pull/12)' ;;
		esac
		id_ok "$owner" && id_ok "$repo" ||
			fail 'a URL ref must name an issue or PR (https://github.com/owner/repo/pull/12)'
		ref="$owner/$repo#$num"
		;;
	esac
	case "$ref" in
	'' | [!A-Za-z0-9#]* | *[!A-Za-z0-9#/_.:-]*) fail 'the ref is empty or not just letters, digits and # / _ . : - (#212, owner/repo#12, ABC-12)' ;;
	esac
	case "$ref" in
	*'#'*'#'*) fail 'a ref has at most one # (#212, owner/repo#12)' ;;
	*'#'*)
		case "${ref##*#}" in
		'' | 0* | *[!0-9]*) fail 'a # in a ref must be followed by an issue or PR number (#212, owner/repo#12)' ;;
		esac
		;;
	esac
	# A URL that wasn't taken above (no scheme, say) would be stored as it is
	# and never match the owner/repo#n a resolve is given.
	case "$ref" in
	*/pull/* | */issues/*) fail 'give a URL ref with its scheme (https://github.com/owner/repo/pull/12), or as owner/repo#12' ;;
	esac
	case "$ref" in
	'#'*)
		url=$(git -C "$PWD" remote get-url origin 2>/dev/null) || url=
		# Less any trailing slashes, which would leave the repo empty.
		url=${url%"${url##*[!/]}"}
		# Only an origin of the shape host:owner/repo or scheme://host/owner/repo
		# names an owner and a repo. A local path, or a host with nested groups,
		# would yield a wrong pair, so there the ref stays bare.
		rest=${url%.git}
		case "$rest" in
		*://*) rest=${rest#*://} rest=${rest#*/} ;;
		/* | .* | *:*:*) rest='' ;;
		*:*) rest=${rest#*:} ;;
		*) rest='' ;;
		esac
		owner=${rest%%/*}
		repo=${rest#*/}
		if [ "$rest" = "$owner/$repo" ] && id_ok "$repo" && id_ok "$owner"; then
			ref="$owner/$repo$ref"
		fi
		;;
	esac
	case "$ref" in
	*/*'#'*) ref="$(printf '%s' "${ref%#*}" | tr '[:upper:]' '[:lower:]')#${ref##*#}" ;;
	esac
	[ "${#ref}" -le 200 ] || fail 'the ref is over 200 bytes'
}

# Check every argument before touching anything.
ref='' has_ref=no why='' text='' need=''
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
	# The text comes from a heredoc; from a terminal, reading would only block.
	[ ! -t 0 ] || fail "$usage"
	# All of stdin, kept exact (the x stops $(...) from stripping trailing
	# newlines), less one trailing newline. A NUL, which a shell variable can't
	# hold and $(...) would silently drop, becomes \001, so the control check
	# below refuses it instead.
	text=$(
		tr '\000' '\001'
		printf x
	)
	text=${text%x}
	text=${text%$'\n'}
	# C0 controls but tab and newline, DEL, and C1 controls as UTF-8 encodes
	# them (U+0080 to U+009F: C2 80 to C2 9F), which some terminals obey too.
	c1=$'*\xc2[\x80-\x9f]*'
	# shellcheck disable=SC2254 # the pattern is meant to match
	case "$text" in
	$c1) fail 'the text has a control character (only tab and newline are kept)' ;;
	esac
	[ "$(printf '%s' "$text" | tr -d '\001-\010\013-\037\177' | wc -c)" -eq "${#text}" ] ||
		fail 'the text has a control character (only tab and newline are kept)'
	# Invisible formatting characters as UTF-8 encodes them: zero-width ones,
	# the marks and bidi embeddings and overrides (U+200B to U+200F: E2 80 8B to
	# 8F; U+2028 to U+202E: E2 80 A8 to AE), the bidi isolates (U+2066 to
	# U+2069: E2 81 A6 to A9), and a byte-order mark (U+FEFF: EF BB BF). Text
	# pasted from an issue can carry one, and it can make `list` read
	# differently from what was recorded.
	fmt=$'*\xe2\x80[\x8b-\x8f\xa8-\xae]*'
	# U+2060 to U+2064 (word joiner, invisible operators) with the isolates.
	iso=$'*\xe2\x81[\xa0-\xa4\xa6-\xa9]*'
	bom=$'*\xef\xbb\xbf*'
	# A soft hyphen (U+00AD), the Arabic letter mark (U+061C), the Mongolian
	# vowel separator (U+180E), interlinear annotation marks (U+FFF9 to
	# U+FFFB), and the tag characters (U+E0000 to U+E007F: F3 A0 80/81 ..),
	# which hide text from a person while a model still reads it.
	shy=$'*\xc2\xad*'
	alm=$'*\xd8\x9c*'
	mvs=$'*\xe1\xa0\x8e*'
	ann=$'*\xef\xbf[\xb9-\xbb]*'
	tag=$'*\xf3\xa0[\x80\x81]*'
	# shellcheck disable=SC2254 # the patterns are meant to match
	case "$text" in
	$fmt | $iso | $bom | $shy | $alm | $mvs | $ann | $tag) fail 'the text has an invisible formatting character (a bidi override or isolate, a zero-width character, a line separator or a byte-order mark)' ;;
	esac
	# The first line is the Why line; the rest, past any blank lines, the text.
	why=${text%%$'\n'*}
	case "$text" in
	*$'\n'*) text=${text#*$'\n'} ;;
	*) text='' ;;
	esac
	case "$why" in
	Why:*) why=${why#Why:} ;;
	*) fail "the first line isn't a Why line: start the text with 'Why: <history and goal>', one short line on why the work exists" ;;
	esac
	# Trimmed of the blanks around it.
	why=${why#"${why%%[![:space:]]*}"}
	why=${why%"${why##*[![:space:]]}"}
	[ -n "$why" ] || fail 'the Why line is empty'
	[ "${#why}" -le 200 ] || fail 'the Why line is over 200 bytes (keep it to one short line)'
	while :; do
		first=${text%%$'\n'*}
		case "$text" in
		*$'\n'*) ;;
		*) break ;;
		esac
		case "$first" in
		*[![:space:]]*) break ;;
		esac
		text=${text#*$'\n'}
	done
	case "$text" in
	*[![:space:]]*) ;;
	*) fail 'the text after the Why line is empty' ;;
	esac
	[ "${#text}" -le 4000 ] || fail 'the text is over 4000 bytes'
	;;
resolve)
	shift
	[ $# -ge 1 ] || fail "$usage"
	if [ "$1" = --ref ]; then
		[ $# -eq 2 ] || fail "$usage"
		ref=$2 has_ref=yes
	else
		[ $# -eq 1 ] || fail "$usage"
		need=$1
		case "$need" in
		n[1-9]*) ;;
		*) fail "'$need' is not a need id (n1, n2, …)" ;;
		esac
		case "${need#n}" in
		*[!0-9]*) fail "'$need' is not a need id (n1, n2, …)" ;;
		esac
		[ "${#need}" -le 10 ] || fail "'$need' is not a need id (n1, n2, …)"
	fi
	;;
list)
	[ $# -eq 1 ] || fail "$usage"
	;;
*) fail "$usage" ;;
esac

sid="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
[ -n "$sid" ] || fail 'no session id (neither CLAUDE_CODE_SESSION_ID nor CLAUDE_SESSION_ID is set)'
id_ok "$sid" || fail 'the session id is not a plain token'
[ -n "${CLAUDE_SESSION_LEDGER_DIR:-}${HOME:-}" ] || fail 'neither CLAUDE_SESSION_LEDGER_DIR nor HOME is set'
dir="${CLAUDE_SESSION_LEDGER_DIR:-$HOME/.claude/session-ledger}"
file="$dir/$sid.jsonl"
# A directory that is there but can't be read fails, rather than reading as
# one without this session's ledger, which would show its open needs as gone.
if [ -d "$dir" ] && { [ ! -r "$dir" ] || [ ! -x "$dir" ]; }; then
	fail 'the ledger directory could not be read'
fi
# A ledger path that is something other than a file (a directory, say) fails
# too: a rename onto a directory would move the new ledger inside it and
# report success.
if [ -e "$file" ] && [ ! -f "$file" ]; then
	fail 'the ledger path is not a regular file'
fi

[ "$has_ref" = no ] || normalize_ref

# What counts as an entry, for every read and every resolve: is-entry.jq
# beside this script, which the SessionStart hook's reaping reads too.
# Anything else a hand edit left is skipped, so one bad line can't break a
# listing, and a resolve leaves it as it is.
script_dir=${BASH_SOURCE[0]%/*}
[ "$script_dir" != "${BASH_SOURCE[0]}" ] || script_dir=.
entry_def=$(cat "$script_dir/is-entry.jq" 2>/dev/null) || fail 'is-entry.jq is missing beside the script'
entry_filter="$entry_def"' fromjson? // empty | select(is_entry)'

# entries: this session's entries, one compact JSON object per line.
entries() {
	jq -cR "$entry_filter" "$file"
}

# replace <command…>: the command's stdout, through a temp file beside the
# ledger and a rename over it.
replace() {
	local tmp
	mkdir -p "$dir" 2>/dev/null || fail 'the ledger directory could not be created'
	tmp=$(mktemp "$dir/.${file##*/}.XXXXXX" 2>/dev/null) || fail 'no temp file could be created in the ledger directory'
	if "$@" >"$tmp" && mv -f "$tmp" "$file"; then
		return 0
	fi
	rm -f "$tmp"
	fail 'the ledger could not be written'
}

# lock: hold the ledger directory's lock until unlock or exit. Every write
# reads the ledger before it replaces it, so without the lock two writes at
# once (two of this session's calls run in parallel) would each drop the
# other's entry, and the SessionStart hook's reaping, which takes it too,
# could delete a ledger a write had just renamed into place. The lock is
# flock(2) on one lock file, `.lock` in the ledger directory, taken by perl on
# descriptor 9, which this shell keeps open: the lock belongs to the open
# file, so it lasts until the shell closes the descriptor, and the kernel
# drops it when the process dies. So a killed write leaves nothing to reclaim,
# and no waiter can remove another's lock (a lock file that could be deleted
# and remade, as a mkdir or symlink lock is, raced exactly that way).
#
# The lock file is never deleted, so a writer can never hold a lock on a file
# another writer has replaced; the reaping skips it. That is why there is one
# for the whole directory rather than one per ledger: a lock file per ledger
# would pile up with nothing able to reap it safely, while writes are few and
# each holds the lock for milliseconds.
lock() {
	local lockfile="$dir/.lock" status
	mkdir -p "$dir" 2>/dev/null || fail 'the ledger directory could not be created'
	{ exec 9>>"$lockfile"; } 2>/dev/null || fail 'the ledger lock file could not be opened'
	perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 2;
		for (1 .. 200) { exit 0 if flock($fh, LOCK_EX | LOCK_NB); select(undef, undef, undef, 0.05) }
		exit 1'
	status=$?
	[ "$status" -ne 1 ] || fail 'another write held the ledger for 10 seconds'
	[ "$status" -eq 0 ] || fail 'the ledger lock could not be taken'
}

# unlock: release the lock, by closing the descriptor that holds it.
unlock() {
	exec 9>&-
}

now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# The jq helpers the listing uses: a date in local time, an entry's heading
# line, its Why line and its indented text, control characters shown as ? (a
# hand-edited file may hold one), and newest-first order.
jq_defs='
def clean: gsub("[\u0001-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2064\u2066-\u2069\ufeff\u00ad\u061c\u180e\ufff9-\ufffb\udb40\udc00-\udb40\udc7f]"; "?");
def when: (.at | (fromdateiso8601? // null)) as $t
	| if $t == null then "?" else ($t | strflocaltime("%Y-%m-%d %H:%M")) end;
def num: (.id[1:] | tonumber? // 0);
def heading: ([.id, when] + (if (.ref | type) == "string" then [.ref] else [] end))
	| map(clean) | join(" · ");
def why: if (.why | type) == "string" then ["    Why: " + (.why | split("\n") | join(" ") | clean)] else [] end;
def body: (.text | split("\n") | map("    " + clean) | join("\n"));
def show: "  " + heading + "\n" + (why + [body] | join("\n"));
def section($title): if length == 0 then empty
	else ($title + " (\(length)):"), (.[] | show) end;
'

# append_entry: the ledger with $entry added on a line of its own.
append_entry() {
	if [ -f "$file" ]; then
		cat "$file" || return 1
		# A ledger without a trailing newline still gets the entry on its own line.
		[ -z "$(tail -c 1 "$file")" ] || echo
	fi
	printf '%s\n' "$entry"
}

# stamp <jq condition on $e>: the ledger with every open need that meets the
# condition stamped resolved. Lines that aren't entries are kept as they are.
stamp() {
	jq -rR --arg at "$now" --arg id "$need" --arg ref "$ref" "$entry_def"'
		(fromjson? // null) as $e
		| if ($e | is_entry) and $e.kind == "need" and $e.resolved_at == null and ('"$1"')
		  then $e + {resolved_at: $at} | tojson else . end' "$file"
}

case "$cmd" in
add-decision | add-need)
	kind=${cmd#add-}
	letter=${kind:0:1}
	# Numbered after the highest id of its kind, read under the lock. Only an id
	# of the form the script writes counts (its letter, then at most nine
	# digits), so a hand-edited one like n1.5 or n1e999 can't break the
	# arithmetic and block every add after it.
	lock
	last=0
	if [ -f "$file" ]; then
		last=$(entries | jq -s --arg k "$kind" --arg l "$letter" \
			'[.[] | select(.kind == $k and (.id | test("^" + $l + "[1-9][0-9]{0,8}$"))) | (.id[1:] | tonumber)] | max // 0') ||
			fail 'the ledger could not be read'
	fi
	# The next id has to fit the form too, or numbering would repeat it.
	[ "$last" -lt 999999999 ] || fail "the ledger has used every $kind id"
	id="$letter$((last + 1))"
	entry=$(jq -cn --arg kind "$kind" --arg id "$id" --arg why "$why" --arg text "$text" --arg ref "$ref" \
		--arg at "$now" --arg cwd "$PWD" \
		'{kind: $kind, id: $id, why: $why, text: $text} + (if $ref == "" then {} else {ref: $ref} end) + {at: $at, cwd: $cwd}') ||
		fail 'the entry could not be built'
	replace append_entry
	unlock
	printf '%s\n' "$id"
	;;
resolve)
	if [ "$has_ref" = yes ]; then
		if [ ! -f "$file" ]; then
			printf 'ledger resolve: no open need has the ref %s\n' "$ref" >&2
			exit 0
		fi
		# The ids are read and stamped under one hold of the lock, so the ones
		# printed are the ones stamped.
		lock
		ids=$(entries | jq -r --arg ref "$ref" 'select(.kind == "need" and .resolved_at == null and .ref == $ref) | .id') ||
			fail 'the ledger could not be read'
		if [ -z "$ids" ]; then
			unlock
			printf 'ledger resolve: no open need has the ref %s\n' "$ref" >&2
			exit 0
		fi
		replace stamp '$e.ref == $ref'
		unlock
		printf '%s\n' "$ids"
		exit 0
	fi
	[ -f "$file" ] || fail 'this session has no ledger'
	lock
	state=$(entries | jq -rs --arg id "$need" \
		'[.[] | select(.kind == "need" and .id == $id)] | if length == 0 then "missing" elif any(.[]; .resolved_at == null) then "open" else "resolved" end') ||
		fail 'the ledger could not be read'
	case "$state" in
	missing) fail "the ledger has no need $need" ;;
	resolved)
		unlock
		printf 'ledger resolve: %s is already resolved\n' "$need" >&2
		exit 0
		;;
	esac
	replace stamp '$e.id == $id'
	unlock
	;;
list)
	if [ ! -f "$file" ]; then
		echo "This session's ledger has no entries."
		exit 0
	fi
	# Read in full before anything is printed, so a ledger that can't be read
	# fails without first claiming it has no entries.
	read_entries=$(entries) || fail 'the ledger could not be read'
	printf '%s\n' "$read_entries" | jq -rs "$jq_defs"'
		sort_by(.at, num) | reverse
		| if length == 0 then "This session'"'"'s ledger has no entries." else
			([.[] | select(.kind == "need" and .resolved_at == null)] | section("Open needs")),
			([.[] | select(.kind == "decision")] | section("Decisions")),
			([.[] | select(.kind == "need" and .resolved_at != null)] | section("Resolved needs"))
		  end' || fail 'the ledger could not be read'
	;;
esac
