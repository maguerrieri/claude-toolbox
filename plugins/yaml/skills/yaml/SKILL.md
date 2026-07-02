---
name: yaml
description: 'Use when writing or editing any YAML value — frontmatter in SKILL.md / command / agent .md files, GitHub Actions workflows, docker-compose, Kubernetes manifests, CI configs — even when the edit feels like prose ("tweak a description", "update the summary"), and especially when the value contains #, colon, or quotes, starts with a special character, or could read as a non-string (no, 3.10, 1:30, version numbers).'
---

# YAML editing: quote decision + parse-verify

## Overview

You already know YAML's traps — the failure mode is not noticing you're in one.
Editing a frontmatter `description:` doesn't feel like "writing YAML", so nothing
fires: an unquoted ` #` silently truncates the value into a comment, and the raw
text still *looks* right. Two habits close the gap: one quoting rule, one
mandatory verify step.

## The quoting rule

Quote the value (single quotes; double only if it contains single quotes or needs
escapes) or use a block scalar (`|` / `>`) **if it contains or could be any of**:

- `#`, `:`, a quote character, or a leading special char (``- ? * & ! % @ ` [ { > |``)
- anything a parser could read as a non-string: `no` / `yes` / `on` / `off` /
  `null`, version numbers (`3.10` → float `3.1`), times (`1:30` → sexagesimal
  `90` in YAML 1.1), dates

When unsure, quote — quoting a string is never wrong. Don't rely on "this parser
is YAML 1.2 so `no` is fine": the file will meet a 1.1 parser eventually.

## Verify after every edit (mandatory)

Never trust the raw text — the truncated-comment failure looks correct to the
eye. Parse the file and assert the value round-trips:

```bash
# plain YAML file
uv run --with pyyaml python3 -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
v = d["jobs"]["test"]["strategy"]["matrix"]["python-version"]  # path to what you edited
print(repr(v))
assert v == ["3.9", "3.10"], v' .github/workflows/ci.yml   # quote siblings too, then assert all-strings

# markdown frontmatter (between the --- markers)
awk '/^---$/{n++; next} n==1' SKILL.md | uv run --with pyyaml python3 -c '
import sys, yaml
v = yaml.safe_load(sys.stdin)["description"]
print(repr(v))
assert "#42" in v, v'   # assert the part after the risky character survived
```

(`yq '.'` works too if installed.) The `assert` matters: print-and-glance repeats
the same eyeballing that missed the truncation. Assert the exact value — or at
minimum the substring after the risky character — came back out.

## Gotcha table

| Symptom | Cause | Fix |
|---|---|---|
| Value silently ends mid-sentence | whitespace + `#` starts a comment in a plain scalar | quote the value |
| `no`/`yes`/`on`/`off` becomes `true`/`false` | YAML 1.1 boolean coercion (the Norway problem: `country: NO`) | quote it |
| `3.10` becomes `3.1` | plain scalar parses as float | quote it |
| `1:30` becomes `90` | YAML 1.1 sexagesimal integers | quote it |
| Parser error about indentation | tab characters — YAML forbids tabs for indentation | use spaces |
| Earlier key's value ignored | duplicate keys: last one silently wins in most parsers | remove/rename the duplicate |
| Block scalar gains/loses trailing newline | `|` vs `>` (keep vs fold newlines), `-` vs `+` chomping | pick explicitly: `|-` strip, `|` single `\n`, `|+` keep all |

## Common mistakes

- **"It's just a description tweak"** — that's the exact edit that shipped a
  truncated command description. Prose-feeling edits inside `---` markers are
  YAML edits.
- **Verifying by re-reading the file** — the broken version reads fine. Only a
  parser tells the truth.
- **Quoting the new value but not checking siblings** — while you're there, a
  30-second parse of the whole file catches pre-existing traps for free.
