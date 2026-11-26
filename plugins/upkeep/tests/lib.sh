# Shared scaffolding for the upkeep test scripts. Source it after setting
# `tmp` (a scratch directory the caller removes), call record once per case,
# and end the script with finish.

pass=0
fail=0

record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$2" "$1" "$3"
	fi
}

finish() { # prints the tally; fails when any case failed
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ]
}

# rows <section> <file>: the rows of one `## <section>` block, header and
# `note:` lines left out.
rows() {
	awk -v s="## $1" '$0 == s { on = 1; head = 1; next } /^## / { on = 0 } on && head { head = 0; next } on && !/^note: / { print }' "$2"
}

# row <section> <first column> <file>: the one row whose first column matches.
row() {
	rows "$1" "$3" | awk -F '\t' -v k="$2" '$1 == k { print; exit }'
}

# col <n>: the n-th tab-separated column of stdin's first line.
col() {
	awk -F '\t' -v n="$1" 'NR == 1 { print $n }'
}

# mkrepo <dir>: an empty repo with a fixed identity and main as its branch.
mkrepo() {
	git init -q -b main "$1"
	git -C "$1" config user.name "Upkeep Test"
	git -C "$1" config user.email "upkeep@example.invalid"
	git -C "$1" config commit.gpgsign false
}

# commit_at <dir> <days ago> <subject>: commit everything staged-or-not with
# both dates set <days ago> days before now.
commit_at() {
	commit_at_when="@$((${UPKEEP_NOW:-$(date +%s)} - $2 * 86400)) +0000"
	git -C "$1" add -A
	GIT_AUTHOR_DATE="$commit_at_when" GIT_COMMITTER_DATE="$commit_at_when" \
		git -C "$1" commit -q --allow-empty -m "$3"
}
