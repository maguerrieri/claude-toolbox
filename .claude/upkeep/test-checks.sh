#!/usr/bin/env bash
# Tests for .claude/upkeep/checks.sh, this repo's own upkeep checks: version
# collisions across open PRs, defaults dependencies missing from the settings
# or the README snippet, and marketplace pins whose ref and sha disagree. gh
# is a stub; git is real, on a scratch repo shaped like this one. Runs under
# macOS /bin/bash 3.2 too:
#
#   bash .claude/upkeep/test-checks.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/checks.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0
record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1))
		printf 'FAIL: %s\n  expected: %s\n  got:      %s\n' "$2" "$1" "$3"
	fi
}
rows() { # rows <section> <file>: a section's rows, header and notes left out
	awk -v s="## $1" '$0 == s { on = 1; head = 1; next } /^## / { on = 0 } on && head { head = 0; next } on && !/^note: / { print }' "$2"
}

repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name "Upkeep Test"
git -C "$repo" config user.email "upkeep@example.invalid"
git -C "$repo" config commit.gpgsign false
cd "$repo" || exit 1
mkdir -p .claude-plugin .claude plugins/defaults/.claude-plugin plugins/a/.claude-plugin plugins/b/.claude-plugin
sha1=1111111111111111111111111111111111111111
sha2=2222222222222222222222222222222222222222
sha3=3333333333333333333333333333333333333333
jq -n --arg s1 "$sha1" --arg s2 "$sha2" --arg s3 "$sha3" '{name: "mkt", plugins: [
	{name: "a", source: "./plugins/a"},
	{name: "ext", source: {source: "github", repo: "o/ext", ref: "v1", sha: $s1}},
	{name: "ext2", source: {source: "github", repo: "o/ext2", ref: "v2", sha: $s2}},
	{name: "ext3", source: {source: "github", repo: "o/ext3", ref: "main", sha: $s3}},
	{name: "ext4", source: {source: "github", repo: "o/ext4", sha: $s3}}]}' >.claude-plugin/marketplace.json
printf '{"name": "defaults", "version": "0.1.0", "dependencies": ["a", "b", "c"]}\n' >plugins/defaults/.claude-plugin/plugin.json
printf '{"name": "a", "version": "1.2.0"}\n' >plugins/a/.claude-plugin/plugin.json
printf '{"name": "b", "version": "0.1.0"}\n' >plugins/b/.claude-plugin/plugin.json
printf '{"enabledPlugins": {"defaults@mkt": true, "a@mkt": true, "c@mkt": false}}\n' >.claude/settings.json
cat >README.md <<'EOF'
# Readme

```json
{ "unrelated": "a@mkt" }
```

```json
{
  "enabledPlugins": {
    "defaults@mkt": true,
    "b@mkt": true,
    "c@mkt": true
  }
}
```
EOF
git add -A
git commit -q -m init

mkdir "$tmp/bin" "$tmp/fx"
manifest() { jq -nc --arg v "$1" '{content: ({version: $v} | tojson | @base64)}'; }
manifest 1.3.0 >"$tmp/fx/a-h1"
manifest 1.3.0 >"$tmp/fx/a-h2"
manifest 1.2.0 >"$tmp/fx/a-h3"
manifest 0.2.0 >"$tmp/fx/b-h1"
manifest 0.1.0 >"$tmp/fx/new-h5"
manifest 0.1.0 >"$tmp/fx/new-h7"
manifest 0.1.0 >"$tmp/fx/other-h8"
manifest 0.2.0 >"$tmp/fx/b-h6"
cat >"$tmp/fx/open.json" <<'EOF'
[{"number": 1, "headRefOid": "h1", "files": [{"path": "plugins/a/x"}, {"path": "plugins/b/y"}, {"path": "plugins/a/q"}]},
 {"number": 2, "headRefOid": "h2", "files": [{"path": "plugins/a/z"}]},
 {"number": 3, "headRefOid": "h3", "files": [{"path": "plugins/a/w"}]},
 {"number": 4, "headRefOid": "h4", "files": [{"path": "docs/x.md"}]},
 {"number": 5, "headRefOid": "h5", "files": [{"path": "plugins/new/x"}]},
 {"number": 7, "headRefOid": "h7", "files": [{"path": "plugins/new/y"}]},
 {"number": 8, "headRefOid": "h8", "files": [{"path": "plugins/other/x"}]}]
EOF
# PR #6 is at gh's 100-file cap; its full list, read by REST, touches plugins/b.
jq '. + [{number: 6, headRefOid: "h6", files: [range(100) | {path: "docs/gen/f\(.).md"}]}]' "$tmp/fx/open.json" >"$tmp/fx/open6.json"
mv "$tmp/fx/open6.json" "$tmp/fx/open.json"
{ i=0; while [ "$i" -lt 100 ]; do echo "docs/gen/f$i.md"; i=$((i + 1)); done; echo plugins/b/late.md; } >"$tmp/fx/pr6-files"
cat >"$tmp/bin/gh" <<STUB_EOF
#!/usr/bin/env bash
fx="$tmp/fx"
case "\$*" in
"pr list -R owner/repo --state open "*) [ "\${STUB_FAIL:-}" = 1 ] && { echo "HTTP 502" >&2; exit 1; }; cat "\$fx/open.json" ;;
"api --paginate repos/owner/repo/pulls/6/files?per_page=100 --jq .[].filename") [ "\${STUB_FAIL:-}" = big ] && exit 1; cat "\$fx/pr6-files" ;;
"api repos/owner/repo/contents/plugins/"*) p=\${2#repos/owner/repo/contents/plugins/}; f="\$fx/\${p%%/*}-\${2##*ref=}"; [ -f "\$f" ] || exit 1; cat "\$f" ;;
"api repos/o/ext/git/ref/tags/v1") echo '{"object": {"type": "tag", "sha": "tagobj"}}' ;;
"api repos/o/ext/git/tags/tagobj") echo '{"object": {"sha": "$sha1"}}' ;;
"api repos/o/ext2/git/ref/tags/v2") echo '{"object": {"type": "commit", "sha": "9999"}}' ;;
"api repos/o/ext3/git/ref/heads/main") echo '{"object": {"type": "commit", "sha": "$sha3"}}' ;;
"api repos/"*) echo '{"message": "Not Found"}'; exit 1 ;;
*) echo "unexpected gh call: \$*" >&2; exit 1 ;;
esac
STUB_EOF
chmod +x "$tmp/bin/gh"
# Links to jq and git alone, so no real gh or claude beside them is on PATH.
mkdir "$tmp/tools"
for tool in jq git; do ln -s "$(command -v "$tool")" "$tmp/tools/$tool"; done
PATH="$tmp/bin:$tmp/tools:/usr/bin:/bin"

bash "$script" --repo owner/repo >"$tmp/out" 2>"$tmp/err"
record 0 "exits 0" "$?"
record "a 1.2.0 #1 1.3.0 collides with #2|a 1.2.0 #2 1.3.0 collides with #1|a 1.2.0 #3 1.2.0 not-above-main|b 0.1.0 #1 0.2.0 collides with #6|b 0.1.0 #6 0.2.0 collides with #1|new new #5 0.1.0 collides with #7|new new #7 0.1.0 collides with #5" \
	"version collisions: shared bumps (one past a PR's 100-file cap, one of a plugin main hasn't got), and one not above main" \
	"$(rows version-collisions "$tmp/out" | sort | tr '\t' ' ' | paste -s -d '|' -)"
record "note: 1 more plugin bumps on open PRs are fine" "a new plugin no other PR adds is fine" \
	"$(grep '^note: .* plugin bumps' "$tmp/out")"
record "a	yes	missing|b	missing	yes|c	disabled	yes" "defaults deps missing from the settings or the README's snippet, or listed but disabled" \
	"$(rows defaults-deps "$tmp/out" | sort | paste -s -d '|' -)"
record "ext2	o/ext2	v2	$sha2	9999	mismatch|ext4	o/ext4	-	$sha3	-	ref-or-sha-missing" \
	"pins: a mismatch and a missing ref; an annotated tag and a branch resolve" \
	"$(rows marketplace-pins "$tmp/out" | sort | paste -s -d '|' -)"
record "note: 4 pinned entries checked" "every github entry is checked" "$(grep '^note: .* pinned' "$tmp/out")"

STUB_FAIL=big bash "$script" --repo owner/repo >"$tmp/nobig" 2>&1
record "note: open PR #6 lists 100 files and its full list failed to read; it may touch more plugins" \
	"a failed full read says so, after the rows" "$(sed -n '/^## version-collisions$/,/^## /p' "$tmp/nobig" | grep '^note: open PR')"
record "plugin	main	pr	pr_version	status" "and the header still comes first" "$(sed -n '/^## version-collisions$/{n;p;}' "$tmp/nobig")"

STUB_FAIL=1 bash "$script" --repo owner/repo >"$tmp/fail" 2>&1
record "skipped: gh pr list failed: HTTP 502" "collisions skip when gh fails" \
	"$(sed -n '/^## version-collisions$/{n;p;}' "$tmp/fail")"
record 1 "the other sections still run" "$(grep -c '^## marketplace-pins$' "$tmp/fail")"

bash "$script" --repo nope >/dev/null 2>&1
record 2 "a bad --repo is a usage error" "$?"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
