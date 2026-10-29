#!/usr/bin/env bash
# gh-verified.sh — a best-effort check, before a push, that GitHub marks
# every commit in a range verified, for START's Signed commits rule and
# FINISH Step 2's signed fast-forward in skills/ticket-workflow/.
#
#   gh-verified.sh <base> <head>
#
# Asks GitHub for the verification of each commit in <base>..<head>, merges
# included (repos/{owner}/{repo}/commits/<sha>, so the commits must be
# pushed first). Prints "<sha> <reason> <subject>" for each one GitHub
# doesn't mark verified, and exits 1 when any isn't. Exits 0 when all are.
# Exits 2 on a usage or setup error: a ref that doesn't resolve, an empty
# range, a shallow clone (its walk can hide commits a push would land), or
# a GitHub read that fails.
#
# It is a courtesy, not the enforcement: GitHub accepts a key registered on
# any GitHub account, so a commit it calls verified can still be one a
# stricter deploy refuses. The deploy, and a rule on the base that requires
# signed commits, are the gates; this only keeps a session from pushing
# what they would plainly refuse.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/gh-verified.sh" …`,
# the same way as role-marker.sh. GH_VERIFIED_GH overrides the gh binary (tests).
set -euo pipefail

fail_setup() {
	echo "gh-verified.sh: $*" >&2
	exit 2
}

[ $# -eq 2 ] || fail_setup "usage: gh-verified.sh <base> <head>"
gh_bin=${GH_VERIFIED_GH:-gh}

[ "$(git rev-parse --is-shallow-repository)" = false ] ||
	fail_setup "this clone is shallow, so the range may hide commits a push would land; run git fetch --unshallow first"
base_sha=$(git rev-parse --verify -q "$1^{commit}") || fail_setup "$1 is not a commit"
head_sha=$(git rev-parse --verify -q "$2^{commit}") || fail_setup "$2 is not a commit"
shas=$(git rev-list "$base_sha..$head_sha") || fail_setup "git rev-list $1..$2 failed"
[ -n "$shas" ] || fail_setup "no commits in $1..$2"

total=0
bad=0
while IFS= read -r sha; do
	total=$((total + 1))
	verdict=$("$gh_bin" api "repos/{owner}/{repo}/commits/$sha" \
		--jq '"\(.commit.verification.verified) \(.commit.verification.reason)"') ||
		fail_setup "can't read $sha's verification from GitHub; push it first"
	case $verdict in "true "*) continue ;; esac
	bad=$((bad + 1))
	printf '%s %s %s\n' "$sha" "${verdict#* }" "$(git log -1 --format=%s "$sha")"
done <<<"$shas"

if [ "$bad" -gt 0 ]; then
	echo "gh-verified.sh: $bad of $total commits in $1..$2 aren't verified by GitHub" >&2
	exit 1
fi
echo "gh-verified.sh: all $total commits in $1..$2 are verified by GitHub" >&2
