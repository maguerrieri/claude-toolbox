# pr-notifier

Wakes the local Claude Code session that owns a PR when the owner or a configured
review bot acts on it, or when it merges or closes. Epic #290 says why: harness PR
events reach only cloud sessions, and a local background session is stopped after it
idles, so a comment on a PR a session opened otherwise reaches nobody. This plugin is
the program that does it (#293). The design follows the #292 spike's findings
(`docs/superpowers/specs/2026-10-31-pr-notifier-spike.md`, *Design corrections for
#290*), which this README cites as "the spike".

It is a plain local process: no model, no tokens. It runs as the macOS user whose
sessions it serves, polls that user's GitHub account through `gh`, and resumes
sessions through `claude`.

## Files

| Path | What |
|---|---|
| `bin/pr-notifier` | The CLI: `subscribe`, `unsubscribe`, `status`, `check` |
| `lib/examine.jq` | The filter: one PR's issue timeline and state, turned into wake events |
| `scripts/owner-check.sh` | Vendored from ticket-workflow (#291), below |
| `scripts/pr-notifier-shim.sh` | What the install copies to the stable path |
| `skills/pr-notifier/SKILL.md` | When sessions call it, and the wake prompt's exact shape |
| `tests/test-pr-notifier.sh` | Tests against stubbed `gh` and `claude` |

## The stable path

Sessions and the launchd job call **`$HOME/.local/bin/pr-notifier`**, never the plugin
cache's own directory, whose name carries the version and changes on every update.
The install (#295) copies `scripts/pr-notifier-shim.sh` there. The shim runs the newest
`pr-notifier/<version>/bin/pr-notifier` it finds under any of the user's config roots
(`~/.claude/plugins/cache/maguerrieri-toolbox/…` and `~/.claude-*/plugins/cache/…`),
so an update needs no reinstall. `PR_NOTIFIER_ROOT` pins a plugin directory instead (a
checkout, or a test). The launchd job runs `"$HOME/.local/bin/pr-notifier" check`.

## State

Everything lives in `$PR_NOTIFIER_HOME`, default `~/.local/state/pr-notifier`, one per
macOS user and shared by all of that user's config roots:

- `registry.json`: the subscriptions. Each records the PR (`owner/repo#n`, lowercased),
  the full session id, the session's name, `CLAUDE_CONFIG_DIR` only if it was set (set
  to `~/.claude` counts as unset: the spike's Trap 3), and `subscribed_at`, two minutes
  before the subscribe so clock skew can't hide a reply that came right after it. No
  launch dir and no `PATH` (the spike's *Subscribe: what to record*).
- `state.json`: the feed's cursor (`Last-Modified`, `since`, the next poll time), each
  PR's cursor (timeline items seen, owner checks being retried, tracked comments, last
  sweep), the sessions' own login, cached owner checks, and the events held per session.
- `config.json`: optional settings (below).
- `notifier.log`: append-only, one line per poll, filtered event (kept or dropped, and
  why), hold, wake, unsubscribe and stale hold. It isn't rotated; the install can add
  that.
- `lock/`: held by any command that writes, so a `subscribe` never races a `check`. A
  lock whose holder died is taken over.

Files are replaced atomically (written beside, then moved).

## One check

`check` takes the lock (or logs `check skipped=locked` and exits 0), then:

1. **Poll the feed**, unless `X-Poll-Interval` (60 seconds) hasn't passed since the
   last poll: `GET /notifications?all=true&since=…` with `If-Modified-Since`, so a quiet
   minute is a 304, which the spike found doesn't count against the rate limit. `since`
   moves only on a 200, and at most hourly (to five minutes before that poll, since a
   thread's `updated_at` can trail its event), so the URL usually repeats and a 304
   stays possible, and a restart catches up from the last 200. A thread on a subscribed
   PR marks that PR to be read.
2. **Read every PR that is marked, or due a sweep** (`sweep_interval`, five minutes):
   the PR itself and its issue timeline. The sweep is what makes a missed notification
   harmless. The spike couldn't yet say whether the owner's reviews and line comments
   move the notification thread (its Q4 owner rows wait on Mari's actions on #296), so
   the feed is only the fast path, and every subscribed PR is read on the sweep whether
   or not a notification came. A failed read leaves the PR marked for the next check.
3. **Filter** each new timeline item (below), and queue each kept event for every
   subscription that existed when it happened.
4. **Deliver** what each session has queued (below), one wake per session however many
   events and PRs it covers.
5. **Report** holds older than `hold_bound`.

Rate cost: one feed request a minute, plus two or three requests per subscribed PR per
sweep (the PR, its timeline pages, and owner checks for new logins), all on the token
the user's other sessions share.

## The filter

It reads the PR's issue timeline, never the notification, which carries no author and
no event type (the spike's *Filter: read the PR, not the notification*). For each new
`commented`, `reviewed` or `line-commented` item at or after the earliest subscription:

| Actor | Verdict |
|---|---|
| The sessions' own login (`gh api user`, cached a day) | dropped |
| A configured review bot, which GitHub also types `Bot` | kept |
| `owner-check.sh -R <owner>/<repo> <login>` exits 0 | kept (the owner) |
| It exits 3 (the sessions post as the owner's account) | dropped |
| Anything else | dropped |

- The bot list (`review_bots`) defaults to `copilot-pull-request-reviewer[bot]`,
  `Copilot` (how the timeline names Copilot's reviews) and
  `chatgpt-codex-connector[bot]`. Requiring GitHub's `Bot` type means a user account
  called `Copilot` is checked like anyone else.
- **owner-check's exit 1 can't tell a stranger from a failed read**, so a dropped item
  is checked again on each read of its PR for `retry_window` (30 minutes) before it
  settles. Only a yes is cached (for `owner_ttl`, an hour). So a GitHub hiccup during an
  owner check delays the owner's event instead of losing it.
- The PR's own state: a merge or a close is kept whoever did it, as `merged` or
  `closed`.
- Codex's clean result edits its old summary comment and adds a 👍, and neither is a
  new timeline item. The filter tracks that comment's `codex-review-state` line and
  keeps the edit as a `review` when it reaches a new completed state.
- An owner's edited comment is kept as `edited`.

## Delivery

Each session is looked up in its own root: `claude agents --json --all` run with the
recorded `CLAUDE_CONFIG_DIR` (unset when it was unset), and its job state at
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/state.json`. Every `claude` call
runs from `/`, with `CLAUDE_SESSION_ID` and `CLAUDE_CODE_SESSION_ID` removed and `PATH`
set to `wake_path`, since that `PATH` becomes the woken session's tool `PATH` (the
spike's Trap 2). First match wins:

| State | Action |
|---|---|
| The listing fails | hold |
| No row for the session | unsubscribe it, drop its events |
| The row's `cwd` is gone (FINISH removed the worktree) | unsubscribe it, drop its events: its resume would be refused |
| Stopped: no `pid` | `claude --bg --resume <session id> "<wake prompt>"`, with no flag but `--bg` (any other flag starts a copy) |
| `status` `busy` or `waiting`, or `state` `working` | hold |
| Any other live state but idle with `state` `done` or `blocked` | hold |
| `inFlight` has tasks, queued input or any kind (monitors included), or can't be read | hold |
| Idle, but active within `idle_grace` (ten minutes) | hold |
| Idle with `state` `done` or `blocked` | re-read the row and job state, `claude stop <short id>`, wait until the row shows no `pid`, then resume as above |

- `state` `blocked` with `status` `idle` is a session that handed back waiting on the
  user: the main thing to wake, never a reason to hold.
- **Attached viewers.** A stop disconnects anyone attached, and attachment isn't
  visible outside Claude Code's daemon. The policy is the idle grace: a live session is
  stopped only after ten minutes without activity, betting that someone attached and
  active keeps it busier than that. The cost when the bet loses is a disconnect (and
  any unsent typing); the conversation itself is kept, and `claude attach` reconnects.
- Checking and stopping aren't atomic: a turn can start between the re-read and the
  stop. The re-read narrows that window; it can't close it.
- A refused resume keeps the events for the next check, and Claude Code keeps the
  refused prompt to deliver with the next wake. The wake prompt is written so getting it
  twice is harmless.
- **Bounded holds.** Holds rest on Claude Code's internal job state, which can change
  between versions. A session held past `hold_bound` (30 minutes) gets one `stale` log
  line and one stderr line from `check`, and stays held; `status` marks it `STALE`.
- After a wake that carried a `merged` or `closed` event, that PR's subscription for
  the session ends.

## The wake prompt

A fixed template carrying only URLs, specified in `skills/pr-notifier/SKILL.md`, which
is the contract ticket-workflow (#294) codes against. It opens with
`pr-notifier wake v1:`.

## Settings

`config.json` in the state directory, every key optional:

| Key | Default | What |
|---|---|---|
| `review_bots` | Copilot (both logins), Codex | Logins that wake when GitHub types them `Bot` |
| `sweep_interval` | `300` | Seconds between reads of each subscribed PR when no notification marks it |
| `retry_window` | `1800` | Seconds an item a failed owner check dropped is checked again |
| `owner_ttl` | `3600` | Seconds an owner check's yes is cached |
| `idle_grace` | `600` | Seconds a live session must be quiet before it is stopped to deliver |
| `hold_bound` | `1800` | Seconds before a held session is reported stale |
| `wake_path` | the notifier's own `PATH` | The `PATH` every `claude` call, and so every woken session, gets |

The install sets `wake_path` (or the job's own `PATH`) to the user's full login-shell
`PATH`, captured once.

## owner-check.sh is vendored

`scripts/owner-check.sh` is a byte-for-byte copy of
`plugins/ticket-workflow/scripts/owner-check.sh` from #291 (PR #297, at its head
`4c8c766` when this was written; not merged yet). The notifier runs under launchd with
no session around it, so neither `CLAUDE_PLUGIN_ROOT` nor `CLAUDE_TICKET_WORKFLOW_ROOT`
is set, and reaching ticket-workflow's copy would mean globbing another plugin's
versioned cache directory, which may not even be installed. #291 kept the script
standalone (`gh` and `git` only) so it could be vendored. The test suite compares the
two copies whenever ticket-workflow's exists, so a change to one fails CI until the
other matches. `PR_NOTIFIER_OWNER_CHECK` points the notifier at another copy.

## Tests

```bash
bash plugins/pr-notifier/tests/test-pr-notifier.sh
```

They run the CLI against stubbed `gh` and `claude` (and the real vendored
`owner-check.sh` on the `gh` stub), in CI through `.github/workflows/pr-notifier-ci.yml`.

## Not here

- ticket-workflow subscribing at START, handling the wake prompt, and unsubscribing at
  FINISH: #294.
- The launchd job, its install script (which writes the shim and the `PATH`), and the
  checklist Mari runs: #295.
- Delivering in place into a live session (typing into a pty-held `claude attach`), the
  only alternative to stop-and-resume the spike found. It drives the interactive UI and
  can collide with someone typing, so it waits until stop-and-resume proves too
  disruptive.
