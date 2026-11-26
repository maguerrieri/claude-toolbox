#!/usr/bin/env bash
# dead.sh: dead weight, for the upkeep survey. Read-only, git only.
#
#   bash dead.sh [--ref <ref>]
#
# Reads the tree at <ref> (default origin/HEAD, else HEAD). Prints two
# sections, each a `## <name>` line, a tab-separated header and its rows:
#
#   unreferenced-files  scripts, tests, fixtures and other code (a file with
#                       a script or code extension, or one under a scripts,
#                       tests, test, bin, lib, tools, fixtures or testdata
#                       directory) that nothing else names:
#                       - code, by its file name, or by its stem where code
#                         imports it (`./model`, `import model`, `from .model
#                         import`, `import pkg.model`);
#                       - a test file (test-*, *_test.*, *.test.*, ...),
#                         which runners find by directory, is `not-in-ci`
#                         when the repo has CI workflows and none names it or
#                         a directory above it as a path of its own (`pytest
#                         tests/`, not `bash tests/test-a.sh`), and
#                         `unreferenced` only in a repo without workflows;
#                       - a fixtures or testdata tree, as one row, when no
#                         file beside it names the directory.
#                       Manifests and entry points tools find by name
#                       (plugin.json, hooks.json, SKILL.md, README, LICENSE,
#                       workflows) are never listed.
#   unreferenced-dirs   top-level directories, and the directories directly
#                       under them, that nothing outside them names: by path
#                       (`dir/`, `./dir`), or for one under the top level, by
#                       its bare path, or by its name from a file beside it.
#                       Dot directories (`.github`, `.claude`), which tools
#                       find by name, are left out.
#
# A name in a comment or a doc counts as a reference: this finds what nothing
# points at, not what nothing runs.
#
# Needs git.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ref=""
while [ $# -gt 0 ]; do
	case "$1" in
	--ref) [ $# -ge 2 ] || upkeep_die "--ref needs a value"; ref=$2; shift 2 ;;
	*) upkeep_die "unknown argument: $1 (usage: dead.sh [--ref <ref>])" ;;
	esac
done
upkeep_need git awk
upkeep_cd_top
if [ -z "$ref" ]; then
	ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=HEAD
fi
git rev-parse -q --verify "$ref^{commit}" >/dev/null || upkeep_die "not a commit: $ref"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-dead.XXXXXX") || upkeep_die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

git -c core.quotePath=false ls-tree -r --name-only "$ref" >"$tmp/tracked"
printf 'note: read at %s (%s)\n' "$ref" "$(git rev-parse --short "$ref")"

# mentions <fixed string>...: the tracked paths that hold any of the strings.
# git grep at a ref prints `<ref>:<path>`; the ref is stripped so paths
# compare.
mentions() {
	upkeep_n=$#
	while [ "$upkeep_n" -gt 0 ]; do
		set -- "$@" -e "$1"
		shift
		upkeep_n=$((upkeep_n - 1))
	done
	git -c core.quotePath=false grep -l -F "$@" "$ref" -- 2>/dev/null |
		awk -v p="$ref:" 'index($0, p) == 1 { $0 = substr($0, length(p) + 1) } { print }'
}
outside() { # outside <dir>: drop the stdin paths under <dir>/
	awk -v d="$1/" 'index($0, d) != 1'
}

awk '
	/(^|\/)\.github\/workflows\// { next }
	/(^|\/)(plugin|hooks|marketplace|package|tsconfig)\.json$/ { next }
	/(^|\/)(SKILL\.md|README[^\/]*|LICENSE[^\/]*|AGENTS\.md|CLAUDE\.md)$/ { next }
	/\.(sh|bash|zsh|py|jq|js|mjs|cjs|ts|tsx|rb|pl|awk|sed)$/ { print; next }
	/(^|\/)(scripts|tests|test|bin|lib|tools|fixtures|testdata)\// && !/\.md$/ { print }
' "$tmp/tracked" >"$tmp/candidates"
grep -E '^\.github/workflows/' "$tmp/tracked" >"$tmp/workflows" || :
while IFS= read -r wf; do git cat-file -p "$ref:$wf" 2>/dev/null; done <"$tmp/workflows" >"$tmp/workflow-text"
: >"$tmp/fixture-roots"

# ci_names <dir>: does a workflow name <dir> as a path of its own (`pytest
# tests/`, `plugin test plugins/x`), not only as part of a longer one?
ci_names() {
	ci_esc=$(printf '%s' "$1" | sed 's/[][\.*^$+?(){}|]/\\&/g')
	grep -q -E "(^|[[:space:]\"'=])(\./)?${ci_esc}/?([[:space:]\"']|$)" "$tmp/workflow-text"
}

upkeep_section unreferenced-files "path	why"
while IFS= read -r file; do
	base=${file##*/}
	dir=${file%/*}
	[ "$dir" = "$file" ] && dir=""
	# Fixtures are found by their directory, so they're judged as a tree.
	case "/$file" in
	*/fixtures/* | */testdata/*)
		printf '%s\n' "$file" | awk -F/ '{
			for (i = 1; i < NF; i++) {
				r = r (i > 1 ? "/" : "") $i
				if ($i == "fixtures" || $i == "testdata") { print r; exit }
			} }' >>"$tmp/fixture-roots"
		continue
		;;
	esac
	# A test file: runners find tests by directory, so the question is
	# whether CI names it, or a directory above it as a path of its own.
	case "$base" in
	test[-_.]* | *_test.* | *.test.* | *-test.*)
		if [ -s "$tmp/workflows" ]; then
			grep -q -F -e "$base" "$tmp/workflow-text" && continue
			ran=no
			d=$dir
			while [ -n "$d" ]; do
				if ci_names "$d"; then
					ran=yes
					break
				fi
				[ "${d#*/}" = "$d" ] && break
				d=${d%/*}
			done
			[ "$ran" = yes ] || printf '%s\tnot-in-ci\n' "$file"
		elif [ -z "$(mentions "$base" | grep -v -x -F -e "$file")" ]; then
			printf '%s\tunreferenced\n' "$file"
		fi
		continue
		;;
	esac
	stem=${base%.*}
	case "$base" in
	*.ts | *.tsx | *.js | *.mjs | *.cjs) refs=$(mentions "$base" "/$stem\"" "/$stem'") ;;
	*.py)
		# `import x`, `from x import`, `from .x import`, `from pkg.x import`,
		# and a dotted `import pkg.x`.
		refs=$(mentions "$base" "import $stem" "from $stem " ".$stem import"
			git -c core.quotePath=false grep -l -E -e "import [A-Za-z0-9_.]*\.$(printf '%s' "$stem" | sed 's/[][\.*^$+?(){}|]/\\&/g')([^A-Za-z0-9_]|\$)" "$ref" -- 2>/dev/null |
				awk -v p="$ref:" 'index($0, p) == 1 { $0 = substr($0, length(p) + 1) } { print }')
		;;
	*) refs=$(mentions "$base") ;;
	esac
	if [ -z "$(printf '%s\n' "$refs" | awk 'NF' | grep -v -x -F -e "$file")" ]; then
		printf '%s\tunreferenced\n' "$file"
	fi
done <"$tmp/candidates"

# A fixture tree counts as used when a file beside it names its directory.
sort -u "$tmp/fixture-roots" | while IFS= read -r root; do
	[ -n "$root" ] || continue
	parent=${root%/*}
	[ "$parent" = "$root" ] && parent=""
	mentions "${root##*/}" | outside "$root" |
		awk -v d="$parent/" 'd == "/" || index($0, d) == 1' | grep -q . && continue
	printf '%s/\tunreferenced fixtures (%s files)\n' "$root" \
		"$(awk -v d="$root/" 'index($0, d) == 1' "$tmp/tracked" | wc -l | tr -d ' ')"
done

upkeep_section unreferenced-dirs "dir	files"
awk -F/ '$1 ~ /^\./ { next } NF >= 2 { print $1 } NF >= 3 { print $1 "/" $2 }' "$tmp/tracked" | sort -u >"$tmp/dirs"
while IFS= read -r d; do
	case "$d" in
	*/*)
		# A second-level directory: named by its path anywhere outside it, or
		# by its name from a file beside it (`$(dirname "$0")/fixtures`).
		mentions "$d" | outside "$d" | grep -q . && continue
		mentions "${d##*/}" | outside "$d" | awk -v p="${d%%/*}/" 'index($0, p) == 1' | grep -q . && continue
		;;
	*)
		# A top-level one: a bare name matches too many words, so only as a
		# path.
		mentions "$d/" "./$d" | outside "$d" | grep -q . && continue
		;;
	esac
	printf '%s\t%s\n' "$d" "$(awk -v d="$d/" 'index($0, d) == 1' "$tmp/tracked" | wc -l | tr -d ' ')"
done <"$tmp/dirs"
