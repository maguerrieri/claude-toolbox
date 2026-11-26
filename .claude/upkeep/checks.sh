#!/usr/bin/env bash
# checks.sh: this repo's own checks for the upkeep survey, named in
# AGENTS.md's `## Upkeep` section. Read-only.
#
#   bash .claude/upkeep/checks.sh [--repo <owner/repo>] [--ref <ref>]
#
# Reads the tree at <ref> (default origin/HEAD, else HEAD) and the open PRs.
# Prints three sections, each a `## <name>` line, a tab-separated header and
# the rows that need attention (or `skipped: <reason>`):
#
#   version-collisions  for each plugin an open PR touches, the version at
#                       the PR's head against <ref>'s and the other open PRs':
#                       `not-above-main` (the plugin versions check fails it
#                       once it's rebased) or `collides` (another open PR
#                       bumps the plugin to the same version, so whichever
#                       merges second has to bump again), or `unread` when the
#                       manifest at the PR's head failed to read (only a 404
#                       counts as the PR removing it). A note counts the rows
#                       that are fine.
#   defaults-deps       `defaults` and each of its dependencies, where it isn't
#                       enabled (`true`) in `.claude/settings.json`'s
#                       enabledPlugins or in the README's settings snippet
#                       (AGENTS.md, *Dogfooding our own plugins*): each cell
#                       reads yes, `disabled` (listed but not true) or
#                       `missing`.
#   marketplace-pins    each marketplace entry sourced from GitHub with a
#                       `ref` and a `sha`, when the commit the ref names isn't
#                       the sha (or the ref can't be found).
#
# Written for macOS /bin/bash 3.2, like the plugins' scripts. Needs gh, git
# and jq.
set -u

die() { printf 'checks: %s\n' "$*" >&2; exit 2; }
repo=""
ref=""
while [ $# -gt 0 ]; do
	case "$1" in
	--repo) [ $# -ge 2 ] || die "--repo needs a value"; repo=$2; shift 2 ;;
	--ref) [ $# -ge 2 ] || die "--ref needs a value"; ref=$2; shift 2 ;;
	*) die "unknown argument: $1 (usage: checks.sh [--repo <owner/repo>] [--ref <ref>])" ;;
	esac
done
for tool in gh git jq awk; do command -v "$tool" >/dev/null 2>&1 || die "needs $tool on PATH"; done
if [ -z "$repo" ]; then
	repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || die "can't tell which GitHub repo this is; pass --repo"
fi
case "$repo" in */*/* | */ | /* | *[!A-Za-z0-9_./-]*) die "not an owner/repo: $repo" ;; */*) ;; *) die "not an owner/repo: $repo" ;; esac
if [ -z "$ref" ]; then
	ref=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null) || ref=HEAD
fi
git rev-parse -q --verify "$ref^{commit}" >/dev/null || die "not a commit: $ref"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/upkeep-checks.XXXXXX") || die "can't make a temp directory"
trap 'rm -rf "$tmp"' EXIT
printf 'note: read at %s (%s)\n' "$ref" "$(git rev-parse --short "$ref")"

# --- version-collisions -----------------------------------------------------
printf '## version-collisions\n'
if gh pr list -R "$repo" --state open -L 500 --json number,headRefOid,files >"$tmp/open.json" 2>"$tmp/err"; then
	# One `<pr>\t<head sha>\t<plugin>` row per plugin each PR touches. gh lists
	# at most 100 files per PR, so a PR at the cap is read in full by REST.
	jq -r '.[] | select((.files | length) < 100) | .number as $n | .headRefOid as $h
		| [.files[]?.path | capture("^plugins/(?<p>[^/]+)/").p] | unique[]
		| [$n, $h, .] | @tsv' "$tmp/open.json" >"$tmp/touched"
	for big in $(jq -r '.[] | select((.files | length) >= 100) | .number' "$tmp/open.json"); do
		head_oid=$(jq -r --argjson n "$big" '.[] | select(.number == $n) | .headRefOid' "$tmp/open.json")
		if ! gh api --paginate "repos/$repo/pulls/$big/files?per_page=100" --jq '.[].filename' >"$tmp/big" 2>/dev/null; then
			jq -r --argjson n "$big" '.[] | select(.number == $n) | .files[]?.path' "$tmp/open.json" >"$tmp/big"
			printf 'note: open PR #%s lists 100 files and its full list failed to read; it may touch more plugins\n' "$big" >>"$tmp/notes"
		fi
		sed -n 's#^plugins/\([^/]*\)/.*#\1#p' "$tmp/big" | sort -u |
			awk -v n="$big" -v h="$head_oid" '{ printf "%s\t%s\t%s\n", n, h, $0 }' >>"$tmp/touched"
	done
	: >"$tmp/versions"
	while IFS='	' read -r pr head plugin; do
		[ -n "$pr" ] || continue
		manifest="plugins/$plugin/.claude-plugin/plugin.json"
		main_v=$(git cat-file -p "$ref:$manifest" 2>/dev/null | jq -r '.version // "?"' 2>/dev/null)
		[ -n "$main_v" ] || main_v=new
		# Only a 404 means the PR removed the manifest; any other failure (a
		# rate limit, a 5xx) is a read that didn't happen, and says so.
		if gh api "repos/$repo/contents/$manifest?ref=$head" >"$tmp/manifest" 2>"$tmp/api-err"; then
			pr_v=$(jq -r '.content | gsub("\n"; "") | @base64d | fromjson | .version // "?"' "$tmp/manifest" 2>/dev/null)
			[ -n "$pr_v" ] || pr_v=unread
		elif grep -q 'HTTP 404' "$tmp/api-err"; then
			pr_v=removed
		else
			pr_v=unread
		fi
		printf '%s\t%s\t%s\t%s\n' "$plugin" "$main_v" "$pr" "$pr_v" >>"$tmp/versions"
	done <"$tmp/touched"
	printf 'plugin\tmain\tpr\tpr_version\tstatus\n'
	jq -Rrs '
		def v: split("-")[0] | split(".") | map(tonumber? // 0);
		def above($a; $b): ($a | v) as $x | ($b | v) as $y | $x > $y;
		[split("\n")[] | select(. != "") | split("\t") | {plugin: .[0], main: .[1], pr: .[2], ver: .[3]}] as $rows
		| [$rows[] | . as $r
			| ([$rows[] | select(.plugin == $r.plugin and .ver == $r.ver and .pr != $r.pr) | "#" + .pr]) as $twins
			| .status = (if .ver == "unread" then "unread: the PR head manifest failed to read"
			             elif .ver == "removed" or .ver == "?" or .main == "?" then "ok"
			             elif .main != "new" and (above(.ver; .main) | not) then "not-above-main"
			             elif $twins != [] then "collides with " + ($twins | join(","))
			             else "ok" end)] as $all
		| ($all[] | select(.status != "ok") | [.plugin, .main, "#" + .pr, .ver, .status] | @tsv),
		  "note: \($all | map(select(.status == "ok")) | length) more plugin bumps on open PRs are fine"' "$tmp/versions"
	[ -f "$tmp/notes" ] && cat "$tmp/notes"
else
	printf 'skipped: gh pr list failed: %s\n' "$(head -1 "$tmp/err")"
fi

# --- defaults-deps ----------------------------------------------------------
printf '## defaults-deps\n'
market=$(git cat-file -p "$ref:.claude-plugin/marketplace.json" 2>/dev/null | jq -r '.name // empty' 2>/dev/null)
deps=$(git cat-file -p "$ref:plugins/defaults/.claude-plugin/plugin.json" 2>/dev/null | jq -r '.dependencies[]?' 2>/dev/null)
if [ -z "$market" ] || [ -z "$deps" ]; then
	printf 'skipped: no marketplace name or no defaults dependencies at %s\n' "$ref"
else
	# `<key>\t<value>` per enabledPlugins entry, from the settings and from
	# the README's snippet (the first ```json block naming enabledPlugins).
	entries='.enabledPlugins // {} | to_entries[] | "\(.key)\t\(.value)"'
	git cat-file -p "$ref:.claude/settings.json" 2>/dev/null | jq -r "$entries" >"$tmp/settings" 2>/dev/null || :
	git cat-file -p "$ref:README.md" 2>/dev/null | awk '
		/^```json[ \t]*$/ { inb = 1; block = ""; next }
		inb && /^```[ \t]*$/ { inb = 0; if (block ~ /"enabledPlugins"/) { printf "%s", block; exit } next }
		inb { block = block $0 "\n" }' >"$tmp/snippet"
	snippet_ok=yes
	jq -r "$entries" "$tmp/snippet" >"$tmp/readme" 2>/dev/null || snippet_ok=no
	printf 'plugin\tsettings\treadme\n'
	# enabled, `disabled` (listed but not true), or `missing`.
	status() { # status <entries file> <key>
		awk -F '\t' -v k="$2" '$1 == k { print ($2 == "true" ? "yes" : "disabled"); found = 1; exit } END { if (!found) print "missing" }' "$1"
	}
	for plugin in defaults $deps; do
		key="$plugin@$market"
		in_settings=$(status "$tmp/settings" "$key")
		in_readme=$(status "$tmp/readme" "$key")
		if [ "$in_settings" != yes ] || [ "$in_readme" != yes ]; then
			printf '%s\t%s\t%s\n' "$plugin" "$in_settings" "$in_readme"
		fi
	done
	[ -s "$tmp/snippet" ] || printf 'note: no README block names enabledPlugins, so every readme cell reads missing\n'
	[ ! -s "$tmp/snippet" ] || [ "$snippet_ok" = yes ] ||
		printf 'note: the README snippet is not valid JSON, so every readme cell reads missing\n'
fi

# --- marketplace-pins -------------------------------------------------------
printf '## marketplace-pins\n'
if git cat-file -p "$ref:.claude-plugin/marketplace.json" >"$tmp/market.json" 2>/dev/null; then
	printf 'entry\trepo\tref\tsha\tref_at\tstatus\n'
	# `-` for a missing field: read merges adjacent tabs, so an empty field
	# would shift the rest.
	jq -r 'def f: if . == null or . == "" then "-" else tostring end;
		.plugins[]? | select((.source | type) == "object" and .source.source == "github")
		| [(.name | f), (.source.repo | f), (.source.ref | f), (.source.sha | f)] | @tsv' "$tmp/market.json" >"$tmp/pins"
	pinned=0
	while IFS='	' read -r entry src pin_ref pin_sha; do
		[ -n "$entry" ] || continue
		pinned=$((pinned + 1))
		if [ "$pin_ref" = - ] || [ "$pin_sha" = - ]; then
			printf '%s\t%s\t%s\t%s\t-\tref-or-sha-missing\n' "$entry" "$src" "$pin_ref" "$pin_sha"
			continue
		fi
		at=""
		for kind in tags heads; do
			obj=$(gh api "repos/$src/git/ref/$kind/$pin_ref" 2>/dev/null | jq -r '"\(.object.type)\t\(.object.sha)"' 2>/dev/null) || obj=""
			case "$obj" in
			tag*) at=$(gh api "repos/$src/git/tags/${obj#*	}" 2>/dev/null | jq -r '.object.sha // empty' 2>/dev/null) ;;
			commit*) at=${obj#*	} ;;
			esac
			[ -n "$at" ] && break
		done
		if [ -z "$at" ]; then
			printf '%s\t%s\t%s\t%s\t-\tref-not-found\n' "$entry" "$src" "$pin_ref" "$pin_sha"
		elif [ "$at" != "$pin_sha" ]; then
			printf '%s\t%s\t%s\t%s\t%s\tmismatch\n' "$entry" "$src" "$pin_ref" "$pin_sha" "$at"
		fi
	done <"$tmp/pins"
	printf 'note: %d pinned entries checked\n' "$pinned"
else
	printf 'skipped: no .claude-plugin/marketplace.json at %s\n' "$ref"
fi
