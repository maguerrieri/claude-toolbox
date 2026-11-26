#!/usr/bin/env bash
# Tests for skills/upkeep/scripts/docs.sh: paths a doc names that the repo
# used to have, and instruction and skill sizes over the window. Builds a
# scratch repo whose history renames and deletes files. Runs under macOS
# /bin/bash 3.2 too:
#
#   bash plugins/upkeep/tests/test-docs.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../skills/upkeep/scripts/docs.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

export UPKEEP_NOW=1795000000
words() { # words <n>: n words on one line
	i=0
	while [ "$i" -lt "$1" ]; do printf 'w%d ' "$i"; i=$((i + 1)); done
	printf '\n'
}

repo="$tmp/repo"
mkrepo "$repo"
mkdir -p "$repo/scripts" "$repo/lib" "$repo/plugins/p/skills/s" "$repo/.claude"
printf '#!/bin/sh\n' >"$repo/scripts/old-name.sh"
printf 'print(1)\n' >"$repo/lib/gone.py"
words 10 >"$repo/plugins/p/skills/s/SKILL.md"
words 40 >"$repo/plugins/p/skills/s/ref.md"
words 5 >"$repo/AGENTS.md"
printf '{}\n' >"$repo/.claude/settings.json"
commit_at "$repo" 200 "start"
commit_at "$repo" 100 "before the window"

git -C "$repo" mv scripts/old-name.sh scripts/new-name.sh
git -C "$repo" rm -q lib/gone.py
git -C "$repo" mv plugins/p/skills/s/ref.md plugins/p/skills/s/reference.md
words 30 >"$repo/plugins/p/skills/s/SKILL.md"
cat >>"$repo/plugins/p/skills/s/SKILL.md" <<'EOF'
See `ref.md` and `reference.md`.
EOF
cat >"$repo/README.md" <<'EOF'
# Readme

Run `scripts/old-name.sh` or `bash ./scripts/new-name.sh:12`, also `new-name.sh`.
The skill lives in `plugins/p/skills/s`, beside `other-repo/file.md`.
Skip `<placeholder>/x.md`, `~/.claude/x.json`, `/abs/path.md`, `--flag.md`, `*.md` and `.md`.
Count `../outside.md` and `.claude/missing-thing` as never tracked.
Runtime: `.claude/worktrees/foo` and `lib/gone.py`.

```bash
bash scripts/old-name.sh   # inside a fence: not a span
```
EOF
commit_at "$repo" 30 "rename and grow"
mkdir -p "$repo/.claude/worktrees/foo"

(cd "$repo" && bash "$script" --days 90) >"$tmp/out" 2>"$tmp/err"
record 0 "exits 0" "$?"
record "README.md:3:readme:scripts/old-name.sh README.md:7:readme:lib/gone.py plugins/p/skills/s/SKILL.md:2:skill:ref.md" \
	"lists only paths the history once held" \
	"$(rows missing-paths "$tmp/out" | awk -F '\t' '{ printf "%s%s:%s:%s:%s", (NR > 1 ? " " : ""), $1, $2, $3, $4 }')"
record "note: 3 more path-like names this repo never tracked (other repos' paths, runtime files, placeholders) left out" \
	"counts the never-tracked ones" "$(grep "^note: [0-9]* more path-like" "$tmp/out")"

record "34	10	+24	1	plugins/p/skills/s/SKILL.md" "SKILL.md grew in the window" "$(row instruction-sizes 34 "$tmp/out")"
record "40	40	+0	1" "a renamed file keeps its size at the window's start" \
	"$(rows instruction-sizes "$tmp/out" | awk -F '\t' '$5 == "plugins/p/skills/s/reference.md" { print $1 "\t" $2 "\t" $3 "\t" $4 }')"
record "5	5	+0	0	AGENTS.md" "AGENTS.md counts, unchanged" "$(rows instruction-sizes "$tmp/out" | awk -F '\t' '$5 == "AGENTS.md"')"
record "74	50	+24	2	plugins/p/skills/s" "the skill's total" "$(rows skill-totals "$tmp/out" | head -1)"
record "" "README isn't an instruction file" "$(rows instruction-sizes "$tmp/out" | awk -F '\t' '$5 == "README.md"')"

(cd "$repo" && bash "$script" --days 300) >"$tmp/long" 2>&1
record "0" "a window older than the repo counts from nothing" \
	"$(rows instruction-sizes "$tmp/long" | awk -F '\t' '$5 == "AGENTS.md" { print $2 }')"
record 1 "and says so" "$(grep -c '^note: no commit before the window starts' "$tmp/long")"

(cd "$repo" && bash "$script" --days 0) >/dev/null 2>&1
record 2 "--days 0 is a usage error" "$?"
(cd "$repo" && bash "$script" --ref nope) >/dev/null 2>&1
record 2 "an unknown ref is a usage error" "$?"

finish
