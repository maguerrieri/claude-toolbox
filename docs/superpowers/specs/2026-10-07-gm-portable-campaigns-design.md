# Portable gm campaigns (fresh clones) — Design

**Date:** 2026-10-07
**Issue:** claude-toolbox #197 (rescoped to fresh clones; the cloud-session part is #198)
**Status:** approved in brainstorming; pending implementation

## Problem

A gm campaign's saves are their own git repo, but a campaign only works on the
machine where it was created. Cloned to another machine or another path, it breaks
in five places (read from gm 0.8.0):

1. **The plugin isn't declared.** gm is enabled at user scope only, so a machine
   without it has no `/gm:play` in that folder.
2. **The commit identity isn't versioned.** `cmd_init` writes `user.name`,
   `user.email` and `commit.gpgsign=false` into `.git/config`, which a clone
   doesn't carry. Autosave then commits as the machine's identity, and blocks or
   fails if that identity signs commits.
3. **`saves:` is an absolute path.** `campaign.md` records the folder's own path,
   and the GM passes it to `campaign bind`, `checkpoint` and the rest. On a clone
   it points somewhere else. `/gm:play` with no argument promises "the most
   recently played campaign", which nothing records.
4. **Rewind would delete committed infra files.** `cmd_rewind` runs
   `git read-tree -u --reset <to>`, so rewinding past the commit that added a file
   deletes it.
5. **Autosave stages everything** (`git add -A`), including local-only paths such
   as `.claude/worktrees/`.

And existing campaigns have no way to opt in.

## Decisions

| Question | Decision |
|---|---|
| Scope | Fresh clones only. Cloud sessions (install hook, autosave binding there, pushing play back) are #198. |
| What the campaign's settings declare | The marketplace and `gm@maguerrieri-toolbox` only. No permission rules: most play runs in auto mode, and the README keeps the allowlist as user-level advice. Not `generate`: forge already degrades without it. No version pin. |
| Where the identity lives | Frozen in the committed `.gm-campaign` marker, applied with `git -c` on every gm commit. |
| Migration entry point | Rerun `campaign init <dir>` on the existing campaign; `/gm:play` offers it. |
| Deferred campaigns | Write nothing; print what to add to the host repo. |
| Finding the campaign | The folder holding `campaign.md`. `/gm:play` with no argument uses the current folder; a path argument stays as the escape hatch. `saves:` is dropped. |
| Who writes the files | `bin/campaign`, not the GM through the Write tool. |

## Design

### Files gm writes

**A new managed campaign** (`campaign init <dir> [--author NAME] [--email EMAIL]`).
The first commit, `gm: start campaign`, holds three files:

- `.gm-campaign`, the existing marker, now carrying the identity. The first line
  stays `gm campaign`; each further line is `key: value`:

  ```
  gm campaign
  author: House GM
  email: house@example.com
  ```

  Without `--author` / `--email`, init records `gm` / `gm@localhost`, the defaults
  it uses today. Newlines in a value are replaced with spaces.
- `.claude/settings.json`:

  ```json
  {
    "extraKnownMarketplaces": {
      "maguerrieri-toolbox": {
        "source": { "source": "github", "repo": "maguerrieri/claude-toolbox" }
      }
    },
    "enabledPlugins": {
      "gm@maguerrieri-toolbox": true
    }
  }
  ```

- `.gitignore`:

  ```
  # Local-only files gm's autosave must not commit
  .claude/settings.local.json
  .claude/worktrees/
  .DS_Store
  ```

Init no longer sets `user.name`, `user.email` or `commit.gpgsign` in `.git/config`.

**An existing managed campaign** (`campaign init <dir>` run again, the *top-up*).
It adds only what's missing and commits it as `gm: make campaign portable`:

- **Identity.** The marker has one when it has both a non-empty `author:` and
  `email:`. If not, the top-up takes them from `--author` / `--email`, else from
  the repo's local `user.name` / `user.email` (which the old init wrote), and
  writes both lines. Flags never replace an identity the marker already has. With
  no source, the top-up still does the rest and prints
  `gm: no commit identity recorded — rerun with --author NAME --email EMAIL`.
- **`.claude/settings.json`.** Created if absent. Otherwise
  `extraKnownMarketplaces["maguerrieri-toolbox"]` and
  `enabledPlugins["gm@maguerrieri-toolbox"]` are each added only when the key is
  absent; an explicit `false` counts as present, and every other key is kept. When
  something is added, the file is rewritten with two-space indentation.
- **`.gitignore`.** Created if absent (as above); otherwise each missing line is
  appended (no comment header), after a newline if the file doesn't end with one.
  A line counts as present when an identical line, ignoring surrounding
  whitespace, is already there.
- **The commit holds only those paths.** It stages and commits just the files the
  top-up changed (`git commit -- <paths>`), so uncommitted play state stays
  uncommitted and never lands under this label.
- **Nothing missing:** prints `already portable: <dir>` and makes no commit, so a
  rerun is safe.
- **Output:** `gm: made campaign portable — added <pieces> (one commit)`, where
  `<pieces>` lists any of `.claude/settings.json`, `.gitignore`, `identity`.

**A deferred campaign** (inside another repo). Unchanged: gm writes nothing and
commits nothing. Init prints the existing `deferred:` line, then the settings JSON
above and the `.gitignore` lines, as what to add to the host repo's own files.

**A repo gm didn't create.** Unchanged: init refuses.

### Commits use the marker's identity

Every commit gm makes goes through one helper: init's first commit, `checkpoint`,
autosave, `rewind`'s two commits, and the top-up. It runs
`git -c commit.gpgsign=false [-c user.name=A -c user.email=E] commit …`:

- the marker's identity, when it has one;
- else nothing extra, so git uses the repo's or the machine's identity (an old
  campaign that hasn't been topped up);
- else, when git has no `user.name` or `user.email` at all, `gm` /
  `gm@localhost`, so autosave never fails on git's "please tell me who you are".

Signing is always off for gm's commits, whatever the global config says. A
`git commit` the player runs by hand uses their own identity.

### Rewind keeps the infra files

After `read-tree -u --reset <to>`, each of `.claude/`, `.gitignore` and
`.gm-campaign` ends up exactly as at HEAD (the pre-rewind checkpoint), in both the
index and the working tree:

- tracked files that only HEAD has come back;
- tracked files that only the target has are removed;
- untracked and ignored files (e.g. `.claude/settings.local.json`) are never
  touched.

Everything else, `.gm/` and `log/raw/` included, rewinds as today.

### Finding the campaign; the top-up offer

- **The campaign is the folder holding `campaign.md`.** `/gm:play` with no
  argument uses the current folder (the project folder Claude Code was started in);
  if there's no `campaign.md` there, the GM says so and suggests starting Claude
  Code in the campaign folder or passing a path. `/gm:play <path>` uses that
  folder: the escape hatch for the bundled demo, a campaign in a vault, or play
  from a parent folder.
- **`saves:` is gone.** `/gm:new-campaign` stops writing it, and the schema drops
  it. An existing `saves:` line stays in the file and is ignored; the docs say so.
  The command docs' `<saves-dir>` placeholder becomes `<campaign-dir>`, so nothing
  points the GM back at the field. The bundled demo's `campaign.md` loses its
  `saves:` line.
- **The offer.** On a managed campaign with missing pieces, `campaign bind` prints
  one more line after its usual output (including the autosave-unavailable line):
  `gm: not portable yet — missing <pieces>; run: campaign init <dir>`. `/gm:play`
  asks the player before running it. If the top-up reports no identity, the GM
  reruns it with `--author` / `--email` from the persona's `chronicle_identity`,
  as `/gm:new-campaign` step 9 already does. Deferred campaigns get no notice.

### Errors

- **`settings.json` isn't valid JSON**, or its top level, `extraKnownMarketplaces`
  or `enabledPlugins` isn't an object: the top-up changes nothing at all (no
  partial top-up), prints
  `refusing: <dir>/.claude/settings.json isn't valid JSON (…); fix it and rerun`,
  and exits non-zero. `bind` treats an unreadable settings file as missing pieces,
  so the notice still appears.
- A git failure in the top-up surfaces like any other `campaign` git failure
  (`campaign: git command failed: …`).

## Out of scope

- The cloud install hook, autosave binding in cloud sessions, and getting cloud
  play back to the campaign's main line: #198.
- Permission rules in the campaign's settings, `generate` in its
  `enabledPlugins`, and a version pin.

## Alternatives rejected

- **Re-resolving the identity from `persona:` at commit time.** The persona's email
  is `<name>@${identity_domain}`, and `${identity_domain}` comes from an env var or
  a gitignored local file. On a machine without either, it resolves to
  `gm.invalid`, so the same campaign would commit as different people on different
  machines. It would also break the README's rule that the identity stays what
  init set when the persona changes.
- **Restoring the identity into `.git/config`.** It works, but a hand-run
  `git commit` would then commit as the persona; `git -c` keeps it to gm's own
  commits.
- **A separate migration subcommand.** Rerunning `init` gives one entry point
  that's already safe to rerun.
- **Having the GM write the files with the Write tool.** The JSON merge would live
  in prose with no tests, and the edit tools treat `.claude/` as a protected path,
  so every write would prompt.
- **Template files in the plugin.** The two files are small; templates would add
  path resolution and a second place to keep in sync.
- **A "most recently played" lookup**, from the binding records gm keeps in its
  data dir. Starting Claude Code in the campaign folder is the normal path now, since
  the committed settings only apply there, and a path argument covers the rest.
- **Stripping old `saves:` lines in the top-up.** It would rewrite the player's
  front-matter for a field nothing reads any more.

## Testing

`plugins/gm/tests/test_campaign.py`:

- `init` writes the three files in a single first commit, with the marker identity
  from the flags, and writes no local `user.name`.
- A checkpoint commits as the marker identity, unsigned, under a hostile global
  config (`GIT_CONFIG_GLOBAL` with a different identity, `commit.gpgsign=true`,
  and a `gpg.program` that fails); likewise in a clone at another path.
- With no identity anywhere (bare marker, empty global config), a checkpoint
  still commits, as `gm` / `gm@localhost`.
- Top-up of a legacy campaign (bare marker plus local `.git/config` identity) adds
  the identity, settings and `.gitignore` in one `gm: make campaign portable`
  commit and leaves other uncommitted changes uncommitted; a rerun prints
  `already portable` and makes no commit.
- Merge rules: other settings keys and an explicit `false` survive; an existing
  `.gitignore` gets only the missing lines; invalid JSON is refused with nothing
  changed.
- Rewinding to a checkpoint from before the settings existed keeps
  `.claude/settings.json`, `.gitignore` and the marker, drops a `.claude/` file
  only the target had, and leaves an ignored `.claude/settings.local.json` alone.
- A deferred campaign's `init` prints the snippet and writes nothing.

`plugins/gm/tests/test_autosave.py`:

- An autosave commit's author is the marker identity.
- `bind` prints the top-up notice for a managed campaign with missing pieces, and
  not for a portable or a deferred one.

The existing tests that read the identity from `.git/config` change to read it
from the marker and the commit author.

Manual check (for `/finish-ticket`'s smoke test): create a campaign, clone it to
another path on a machine without gm at user scope, trust the folder, and run
`/gm:play` there. gm installs, the session binds, and autosave commits as the
persona's identity.

## Docs

- `plugins/gm/README.md`: *Install* (a campaign declares gm itself; the
  permission allowlist stays user-level advice) and *Play* (start Claude Code in
  the campaign folder; existing campaigns are offered the top-up; the identity
  lives in `.gm-campaign`).
- `skills/gm/references/state-schema.md`: the layout gains `.claude/settings.json`,
  `.gitignore` and `.gm-campaign`; `saves:` is removed, with a note that old lines
  are ignored.
- `skills/gm/SKILL.md`: session start (which folder is the campaign; the top-up
  offer) and *Versioning* (the identity comes from the marker).
- `commands/new-campaign.md` (step 5 drops `saves:`; step 9 says what init
  commits), `commands/play.md` (the no-argument case and the offer), and
  `<saves-dir>` → `<campaign-dir>` across the command docs.
- `examples/embervale/campaign.md`: drop `saves:`.
- `AGENTS.md`: only if a new gotcha comes up.

## Release

gm `0.8.0` → `0.9.0` (minor: a new feature). The `plugin versions` check requires
the bump for any behavior change.
