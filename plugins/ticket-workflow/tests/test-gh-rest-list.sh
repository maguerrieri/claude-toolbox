#!/usr/bin/env bash
# Tests for scripts/gh-rest-list.sh, which walks a GitHub REST list page by
# page for github-rest.md: page boundaries, --key, --pages, argument passing
# and gh failures. gh is replaced by a stub that serves a list of a given
# length 100 items a page. Needs jq.
#
#   bash plugins/ticket-workflow/tests/test-gh-rest-list.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/gh-rest-list.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

# The stub serves $STUB_TOTAL items (ids 1..N), 100 a page, as a bare array or,
# with STUB_KEY set, wrapped in {"<key>": [...]}. It logs its arguments to
# $tmp/args and fails when STUB_FAIL_PAGE matches the page asked for.
cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
page=1
for a in "$@"; do case $a in page=*) page=${a#page=} ;; esac; done
[ "${STUB_FAIL_PAGE:-}" = "$page" ] && { echo 'HTTP 403' >&2; exit 1; }
start=$(( (page - 1) * 100 + 1 ))
end=$(( page * 100 ))
[ "$end" -gt "$STUB_TOTAL" ] && end=$STUB_TOTAL
jq -c -n --argjson s "$start" --argjson e "$end" --arg k "${STUB_KEY:-}" \
	'[range($s; $e + 1) | {id: .}] | if $k == "" then . else {total_count: 0, ($k): .} end'
STUB_EOF
chmod +x "$tmp/gh"
export GH_REST_LIST_GH="$tmp/gh" STUB_ARGS="$tmp/args"

run() { # run <total> [script args...]: prints the output's shape, or "exit <n>"
	local total=$1
	shift
	: >"$tmp/args"
	if out=$(STUB_TOTAL=$total bash "$script" "$@" 2>"$tmp/err"); then
		printf '%s' "$out"
	else
		printf 'exit %s' "$?"
	fi
}

record '0' 'empty list' "$(run 0 'repos/o/r/issues' | jq length)"
record '1' 'empty list asks once' "$(wc -l <"$tmp/args" | tr -d ' ')"
record '30' 'one short page' "$(run 30 'repos/o/r/issues' | jq length)"
record '250' 'three pages' "$(run 250 'repos/o/r/issues' | jq length)"
record '1,250' 'items in order' "$(run 250 'repos/o/r/issues' | jq -r '"\(.[0].id),\(.[-1].id)"')"
record '3' 'three pages asked' "$(wc -l <"$tmp/args" | tr -d ' ')"
record '100' 'exactly one full page' "$(run 100 'repos/o/r/issues' | jq length)"
record '2' 'a full page asks for the next' "$(wc -l <"$tmp/args" | tr -d ' ')"
record '[100,50]' '--pages keeps the slurp shape' "$(run 150 'repos/o/r/issues' --pages | jq -c 'map(length)')"
record '120' '--key unwraps the list' "$(STUB_KEY=check_runs run 120 'repos/o/r/commits/x/check-runs' --key check_runs | jq length)"
record 'exit 5' 'a wrapped list without --key fails' "$(STUB_KEY=check_runs run 10 'repos/o/r/commits/x/check-runs')"

run 5 'repos/o/r/issues' -f state=open -f 'labels=epic:repo split' >/dev/null
record 'api -X GET repos/o/r/issues -f state=open -f labels=epic:repo split -f per_page=100 -f page=1' \
	'arguments pass through' "$(head -1 "$tmp/args")"

record '[100,10]' '--pages after a gh argument' "$(run 110 'repos/o/r/issues' -f state=all --pages | jq -c 'map(length)')"

record 'exit 1' 'gh failing on page 2 fails the run' "$(STUB_FAIL_PAGE=2 run 150 'repos/o/r/issues')"
record 'exit 2' 'no endpoint' "$(run 0)"

finish
