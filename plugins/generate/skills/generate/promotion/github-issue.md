# Promotion adapter: github-issue

Opens a **GitHub issue** as the decision ticket. Requires the `gh` CLI
authenticated for the repo. Good when your decisions live as issues. Select with
`Promotion: github-issue`.

## OPEN(type, slot, rivals)

Create an issue titled for the contested slot, body seeding the rivals as the
starting options:

```bash
gh issue create --title "<slot>" --body "$(cat <<'EOF'
Promoted from the <type> reservoir — two pooled items now compete for one slot.

## Decide
Which (if any) takes this slot — or do they merge, or both defer?

## Starting options (from the reservoir, verbatim)
- **<rival 1 name>** — <axis-tags> — <1-line gist>
- **<rival 2 name>** — <axis-tags> — <1-line gist>
EOF
)"
```

Return the issue URL `gh` prints. (Add `--label`/`--assignee` if your repo uses
them.)

## BACKLINK(ref)

Add one line under the reservoir's `## Cold storage` section:

```
promoted <date>: <slot> → <issue ref>
```

The rivals stay in the pool / cold storage; nothing is deleted (kill ≠ delete).
