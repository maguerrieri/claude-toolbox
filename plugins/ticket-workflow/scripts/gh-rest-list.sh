#!/usr/bin/env bash
# gh-rest-list.sh — every page of a GitHub REST list endpoint, for the cloud
# spellings in skills/ticket-workflow/github-rest.md.
#
#   gh-rest-list.sh <endpoint> [--key <field>] [--pages] [-f key=value ...]   (in any order)
#
# Prints one JSON array holding every item of every page. --key names the
# array field when the endpoint wraps its list in an object (check-runs:
# --key check_runs). --pages prints an array of pages instead, the shape
# `gh api --paginate --slurp` gives, so a jq filter written for that reads
# this output unchanged. Any other arguments go to `gh api` as is (query
# parameters as -f, which gh URL-encodes).
#
# Why not `gh api --paginate`: it follows GitHub's Link header, whose
# next-page URL is `repositories/<id>/…`, and the cloud proxy refuses that
# path with HTTP 403. gh still exits 0 having printed page 1, so a list past
# 100 items is silently cut. This script asks for page=1, 2, … on the
# endpoint as given and stops at the first page shorter than 100. A page
# that repeats the one before it (an endpoint that ignores page=) exits 3.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-rest-list.sh" …`,
# the same way as role-marker.sh. GH_REST_LIST_GH overrides the gh binary (tests).
set -euo pipefail

usage() {
	echo "usage: gh-rest-list.sh <endpoint> [--key <field>] [--pages] [gh api args...]" >&2
	exit 2
}

[ $# -ge 1 ] || usage
endpoint=$1
shift
key=
pages=false
gh_args=()
while [ $# -gt 0 ]; do
	case $1 in
	--key) [ $# -ge 2 ] || usage; key=$2; shift 2 ;;
	--pages) pages=true; shift ;;
	*) gh_args+=("$1"); shift ;;
	esac
done

gh_bin=${GH_REST_LIST_GH:-gh}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

page=1
prev=
while :; do
	out=$dir/page-$(printf '%06d' "$page")
	"$gh_bin" api -X GET "$endpoint" ${gh_args[@]+"${gh_args[@]}"} -f per_page=100 -f page="$page" |
		jq -c --arg k "$key" '(if $k == "" then . else .[$k] end)
			| if type == "array" then . else error("not a list (\(type)); pass --key <field>") end' >"$out"
	# An endpoint that ignores page= serves the same full page forever.
	if [ -n "$prev" ] && cmp -s "$prev" "$out"; then
		echo "gh-rest-list.sh: page $page repeats page $((page - 1)); $endpoint ignores page=" >&2
		exit 3
	fi
	[ "$(jq length "$out")" -lt 100 ] && break
	prev=$out
	page=$((page + 1))
done

if $pages; then
	jq -c -s . "$dir"/page-*
else
	jq -c -s 'add' "$dir"/page-*
fi
