#!/usr/bin/env bash
# docs.sh: docs and instructions, for the upkeep survey. Read-only, git only.
#
#   bash docs.sh [--ref <ref>] [--days <n>]
#
# Reads the tree at <ref> (default: origin's default branch as the clone last
# fetched it, origin/HEAD, else HEAD), never the working tree, so it reports
# what the default branch says. The window is the last <n> days (default 90).
# Prints three sections, each a `## <name>` line, a tab-separated header and
# its rows:
#
#   missing-paths       inline code spans in tracked Markdown, outside fenced
#                       blocks, that name a repo path which resolves nowhere
#                       at <ref>: not a tracked file or directory, not the
#                       tail of one (`scripts/x.sh` for `plugins/p/scripts/
#                       x.sh`), not relative to the doc, and not present on
#                       disk, untracked, in the main checkout (runtime paths
#                       such as `.claude/worktrees/`). A span word counts as a path
#                       when it ends in a file extension the repo uses, or has
#                       a `/` and starts with a directory name the repo has.
#                       Placeholders and globs (`<`, `*`, `$`, `{`, `~`, ...),
#                       absolute paths, URLs and flags are skipped. Only a
#                       path the default branch's history once held (renamed
#                       or deleted since) is listed; the rest, which name
#                       other repos' files, runtime files or placeholders far
#                       more often than drift, are only counted, on a `note:`
#                       line. `kind` says what the doc is: instructions,
#                       skill, readme, or doc.
#   instruction-sizes   instruction and skill files (AGENTS.md, CLAUDE.md,
#                       GEMINI.md, Markdown under `.claude/`, and Markdown
#                       under a `skills`, `commands` or `agents` directory),
#                       largest first: words now, words at the window's start
#                       (under the name it had then, when git sees a rename;
#                       `new` for a file the window added, which may hold text
#                       moved out of another file), the change, and commits
#                       in the window.
#   skill-totals        per skill directory (`.../skills/<name>/`), largest
#                       first: words now, words in the whole directory at the
#                       window's start (files deleted since included), the
#                       change, and the files it has now.
#
# Needs git and jq.
set -u
here=$(cd "$(dirname "$0")" && pwd)
. "$here/lib.sh"

ref=""
days=90
while [ $# -gt 0 ]; do
	case "$1" in
	--ref) [ $# -ge 2 ] || upkeep_die "--ref needs a value"; ref=$2; shift 2 ;;
	--days) [ $# -ge 2 ] && upkeep_days_ok "$2" || upkeep_die "--days needs a whole number of days"; days=$2; shift 2 ;;
	*) upkeep_die "unknown argument: $1 (usage: docs.sh [--ref <ref>] [--days <n>])" ;;
	esac
done
upkeep_need git jq awk
upkeep_cd_top
if [ -z "$ref" ]; then
	ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=HEAD
fi
git rev-parse -q --verify "$ref^{commit}" >/dev/null || upkeep_die "not a commit: $ref"
since=$(upkeep_since "$days")
main=$(upkeep_main_checkout)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-docs.XXXXXX") || upkeep_die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT

git -c core.quotePath=false ls-tree -r --name-only "$ref" >"$tmp/tracked"
printf 'note: read at %s (%s), window since %s\n' "$ref" "$(git rev-parse --short "$ref")" "$since"

# --- missing-paths ----------------------------------------------------------
grep -E '\.md$' "$tmp/tracked" >"$tmp/docs" || :
: >"$tmp/spans"
while IFS= read -r doc; do
	git cat-file -p "$ref:$doc" 2>/dev/null | awk -v doc="$doc" '
		/^[ \t]*(```|~~~)/ { fence = !fence; next }
		fence { next }
		{
			line = $0
			while (match(line, /`[^`]+`/)) {
				span = substr(line, RSTART + 1, RLENGTH - 2)
				n = split(span, words, /[ \t]+/)
				for (i = 1; i <= n; i++) if (words[i] != "") printf "%s\t%d\t%s\n", doc, NR, words[i]
				line = substr(line, RSTART + RLENGTH)
			}
		}' >>"$tmp/spans"
done <"$tmp/docs"

# Every path the default branch's history ever held, to tell a path that was
# renamed or deleted from one this repo never had (another repo's, a runtime
# file's, a placeholder's).
git -c core.quotePath=false log "$ref" --format= --name-only 2>/dev/null | awk 'NF' | sort -u >"$tmp/history"

# Resolve each span word against the tracked tree: exact, as the tail of a
# tracked path at a `/`, or relative to the doc's own directory. One that
# doesn't resolve is printed with `removed` when it resolves the same way in
# the history, else with `never`.
awk -F '\t' -v sq="'" -v ell="…" -v tree="$tmp/tracked" -v hist="$tmp/history" '
	function norm(p,   n, parts, out, i, k) {
		n = split(p, parts, "/"); k = 0
		for (i = 1; i <= n; i++) {
			if (parts[i] == "" || parts[i] == ".") continue
			if (parts[i] == "..") { if (k > 0) k--; else return ""; continue }
			out[++k] = parts[i]
		}
		p = ""
		for (i = 1; i <= k; i++) p = p (i > 1 ? "/" : "") out[i]
		return p
	}
	function load(p, set, tails,   n, parts, i, j, t, dir) {
		set[p] = 1
		n = split(p, parts, "/")
		t = parts[n]; tails[t] = 1
		for (i = n - 1; i >= 1; i--) { t = parts[i] "/" t; tails[t] = 1 }
		dir = ""
		for (i = 1; i < n; i++) {
			dir = dir (i > 1 ? "/" : "") parts[i]; set[dir] = 1
			if (set_is_tree) dirname[parts[i]] = 1
			t = parts[i]; tails[t] = 1
			for (j = i - 1; j >= 1; j--) { t = parts[j] "/" t; tails[t] = 1 }
		}
	}
	FILENAME == tree { set_is_tree = 1; load($0, have, have_tail); next }
	FILENAME == hist { set_is_tree = 0; load($0, was, was_tail); next }
	{
		doc = $1; line = $2; w = $3
		sub(/:[0-9]+(-[0-9]+)?$/, "", w)
		sub(/^\.\//, "", w)
		sub(/\/+$/, "", w)
		if (w == "" || w ~ /^\.+$/ || w ~ /^\.[A-Za-z0-9]+$/ || w ~ /^[-\/]/ || w ~ /:\/\//) next
		if (w ~ /[][<>*${}~@=|?(),"\\#!:;`%^&+]/ || index(w, sq) || index(w, ell)) next
		first = w; sub(/\/.*/, "", first)
		ext = (w ~ /\.(md|sh|bash|json|jsonl|jq|py|js|mjs|ts|tsx|yml|yaml|toml|txt|plist|tmpl)$/)
		if (!ext && !(w ~ /\// && (first in dirname))) next
		if (w in have || w in have_tail) next
		d = doc; if (d ~ /\//) sub(/\/[^\/]*$/, "", d); else d = ""
		r = norm((d == "" ? "" : d "/") w)
		if (r != "" && r in have) next
		history = (w in was || w in was_tail || (r != "" && r in was)) ? "removed" : "never"
		kind = "doc"
		if (doc ~ /(^|\/)(AGENTS|CLAUDE|GEMINI)\.md$/ || doc ~ /^\.claude\//) kind = "instructions"
		else if (doc ~ /(^|\/)(skills|commands|agents|rules)\//) kind = "skill"
		else if (doc ~ /(^|\/)README[^\/]*$/) kind = "readme"
		printf "%s\t%s\t%s\t%s\t%s\n", doc, line, kind, w, history
	}' "$tmp/tracked" "$tmp/history" "$tmp/spans" | sort -u -t '	' -k1,1 -k2,2n -k4,4 >"$tmp/missing"

upkeep_section missing-paths "doc	line	kind	path"
never=0
while IFS='	' read -r doc line kind word history; do
	[ -n "$doc" ] || continue
	# A runtime path: on disk in the main checkout but untracked there. A
	# tracked file there is only a checkout behind <ref>, so it still counts.
	if [ -n "$main" ] && [ -e "$main/$word" ] &&
		! git -C "$main" ls-files --error-unmatch -- "$word" >/dev/null 2>&1; then
		continue
	fi
	if [ "$history" = removed ]; then
		printf '%s\t%s\t%s\t%s\n' "$doc" "$line" "$kind" "$word"
	else
		never=$((never + 1))
	fi
done <"$tmp/missing"
printf 'note: %d more path-like names this repo never tracked (other repos'"'"' paths, runtime files, placeholders) left out\n' "$never"

# --- instruction-sizes and skill-totals -------------------------------------
# The default branch as it stood then: along first parents, so a merged
# feature branch's older commit can't stand in for it.
start=$(git rev-list -1 --first-parent --before="$since" "$ref" 2>/dev/null)
git -c core.quotePath=false log --since="$since" --format= --name-only "$ref" 2>/dev/null | awk 'NF { n[$0]++ } END { for (p in n) printf "%s\t%d\n", p, n[p] }' >"$tmp/commits"
grep -E '(^|/)(AGENTS|CLAUDE|GEMINI)\.md$|^\.claude/.*\.md$|(^|/)(skills|commands|agents)/.*\.md$' "$tmp/docs" >"$tmp/instr" || :
# What each file was called at the window's start, where git sees a rename.
: >"$tmp/renames"
[ -z "$start" ] || git diff -M --name-status "$start" "$ref" 2>/dev/null |
	awk -F '\t' '$1 ~ /^R/ { printf "%s\t%s\n", $3, $2 }' >"$tmp/renames"
while IFS= read -r f; do
	now_w=$(git cat-file -p "$ref:$f" 2>/dev/null | wc -w | tr -d ' ')
	was=$(awk -F '\t' -v f="$f" '$1 == f { print $2; exit }' "$tmp/renames")
	[ -n "$was" ] || was=$f
	if [ -n "$start" ] && git cat-file -e "$start:$was" 2>/dev/null; then
		then_w=$(git cat-file -p "$start:$was" | wc -w | tr -d ' ')
	else
		then_w=new
	fi
	printf '%s\t%s\t%s\n' "$f" "$now_w" "$then_w"
done <"$tmp/instr" >"$tmp/sizes"

upkeep_section instruction-sizes "words	words_at_start	change	commits	path"
awk -F '\t' -v counts="$tmp/commits" 'FILENAME == counts { c[$1] = $2; next }
	{ printf "%d\t%s\t%s\t%d\t%s\n", $2, $3, ($3 == "new" ? "new" : sprintf("%+d", $2 - $3)), ($1 in c ? c[$1] : 0), $1 }' \
	"$tmp/commits" "$tmp/sizes" | sort -t '	' -k1,1nr -k5,5
[ -n "$start" ] || printf 'note: no commit before the window starts, so every file reads as new\n'

# A skill's total at the window's start comes from its whole tree then,
# files deleted since included, so a skill that shrank reads as shrinking.
: >"$tmp/start-sizes"
if [ -n "$start" ]; then
	git -c core.quotePath=false ls-tree -r --name-only "$start" 2>/dev/null | grep -E '(^|/)skills/[^/]+/.*\.md$' |
		while IFS= read -r f; do
			printf '%s\t%s\n' "$f" "$(git cat-file -p "$start:$f" 2>/dev/null | wc -w | tr -d ' ')"
		done >"$tmp/start-sizes"
fi
upkeep_section skill-totals "words	words_at_start	change	files	skill"
awk -F '\t' -v then="$tmp/start-sizes" '
	function skill(p) { if (match(p, /(^|\/)skills\/[^\/]+\//)) return substr(p, 1, RSTART + RLENGTH - 2); return "" }
	FILENAME == then { d = skill($1); if (d != "") { s[d] += $2; seen[d] = 1 } next }
	{ d = skill($1); if (d != "") { w[d] += $2; f[d]++; seen[d] = 1 } }
	END { for (d in seen) printf "%d\t%d\t%+d\t%d\t%s\n", w[d], s[d], w[d] - s[d], f[d], d }' \
	"$tmp/start-sizes" "$tmp/sizes" | sort -t '	' -k1,1nr -k5,5
