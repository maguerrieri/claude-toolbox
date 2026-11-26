#!/usr/bin/env bash
# Tests for skills/upkeep/scripts/dead.sh: unreferenced code, tests no CI
# workflow runs, unreferenced fixture trees and directories. Builds a scratch
# repo; git only. Runs under macOS /bin/bash 3.2 too:
#
#   bash plugins/upkeep/tests/test-dead.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
script="$here/../skills/upkeep/scripts/dead.sh"
tmp=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

repo="$tmp/repo"
mkrepo "$repo"
cd "$repo" || exit 1
mkdir -p scripts lib hooks tools tests/fixtures sub/tests other/fixtures orphan-dir .github/workflows .claude-plugin checks src/pkg
cat >README.md <<'EOF'
Run `scripts/used.sh`, `tools/run.py` and the hooks in `hooks/register.tsx`; test with `tests/test-a.sh`.
The app is `src/app.py`.
EOF
printf 'echo used\n' >scripts/used.sh
printf 'echo nobody\n' >scripts/orphan.sh
printf 'import { m } from "../lib/model"\n' >hooks/register.tsx
printf 'export const m = 1\n' >lib/model.ts
printf 'export const u = 1\n' >lib/unused.ts
printf 'from helper import x\n' >tools/run.py
printf 'x = 1\n' >lib/helper.py
printf 'cat "$(dirname "$0")/fixtures/data.json"\n' >tests/test-a.sh
printf 'echo b\n' >tests/test-b.sh
printf 'def test_c(): pass\n' >sub/tests/test_c.py
printf 'def test_x(): pass\n' >checks/test_x.py
printf 'from .model import M\nimport pkg.helper2\n' >src/app.py
printf 'M = 1\n' >src/model.py
printf 'h = 2\n' >src/pkg/helper2.py
printf '{}\n' >tests/fixtures/data.json
printf '{}\n' >other/fixtures/x.json
printf '{}\n' >other/fixtures/y.json
printf 'nothing names me\n' >orphan-dir/thing.txt
printf '{"name": "p"}\n' >.claude-plugin/plugin.json
cat >.github/workflows/ci.yml <<'EOF'
jobs:
  t:
    steps:
      - run: bash tests/test-a.sh
      - run: pytest sub/tests
      - run: pytest checks/
EOF
commit_at "$repo" 1 "init"

bash "$script" >"$tmp/out" 2>"$tmp/err"
record 0 "exits 0" "$?"
record "lib/unused.ts:unreferenced other/fixtures/:unreferenced fixtures (2 files) scripts/orphan.sh:unreferenced tests/test-b.sh:not-in-ci" \
	"the unreferenced files, sorted by section order" \
	"$(rows unreferenced-files "$tmp/out" | sort | awk -F '\t' '{ printf "%s%s:%s", (NR > 1 ? " " : ""), $1, $2 }')"
record "" "an import by stem counts (lib/model.ts)" "$(row unreferenced-files lib/model.ts "$tmp/out")"
record "" "a Python import counts (lib/helper.py)" "$(row unreferenced-files lib/helper.py "$tmp/out")"
record "" "so does a relative one (from .model import)" "$(row unreferenced-files src/model.py "$tmp/out")"
record "" "and a dotted one (import pkg.helper2)" "$(row unreferenced-files src/pkg/helper2.py "$tmp/out")"
record "" "a test in a top-level directory CI runs (pytest checks/) isn't listed" "$(row unreferenced-files checks/test_x.py "$tmp/out")"
record "" "a test CI runs by directory isn't listed" "$(row unreferenced-files sub/tests/test_c.py "$tmp/out")"
record "" "a fixture tree its tests name isn't listed" "$(rows unreferenced-files "$tmp/out" | grep 'tests/fixtures')"
record "" "manifests are never listed" "$(rows unreferenced-files "$tmp/out" | grep 'plugin.json')"
record "orphan-dir other other/fixtures" "unreferenced directories, dot directories left out" \
	"$(rows unreferenced-dirs "$tmp/out" | cut -f1 | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
record "1" "a directory's file count" "$(row unreferenced-dirs orphan-dir "$tmp/out" | col 2)"

# From a subdirectory: the same report as from the top.
(cd "$repo/scripts" && bash "$script") >"$tmp/sub" 2>&1
record "$(grep -v '^note:' "$tmp/out")" "a run from a subdirectory reads the whole tree" "$(grep -v '^note:' "$tmp/sub")"

# Without workflows, a test nothing names is plainly unreferenced.
git rm -q -r .github
commit_at "$repo" 0 "drop CI"
bash "$script" >"$tmp/noci" 2>&1
record "unreferenced" "no CI: an unnamed test is unreferenced" "$(row unreferenced-files tests/test-b.sh "$tmp/noci" | col 2)"
record "" "no CI: a test another file names is fine" "$(row unreferenced-files tests/test-a.sh "$tmp/noci")"

bash "$script" --ref nope >/dev/null 2>&1
record 2 "an unknown ref is a usage error" "$?"

finish
