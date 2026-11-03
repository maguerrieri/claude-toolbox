# pr-notifier

Wakes the local Claude Code session that owns a PR when the owner or a configured
review bot acts on it, or when it merges or closes. Epic #290 says why: harness PR
events reach only cloud sessions, and a local background session is stopped after it
idles, so a comment on a PR a session opened otherwise reaches nobody. This plugin is
the program that does it (#293). The design follows the #292 spike's findings
(`docs/superpowers/specs/2026-10-31-pr-notifier-spike.md`, *Design corrections for
#290*), which this README cites as "the spike".

It is a plain local process, with no model of its own: only a relay wake (below) runs
a short Haiku session. It runs as the macOS user whose
sessions it serves, polls that user's GitHub account through `gh`, and wakes
sessions through `claude`: a live one by a relay's message, a stopped one by a resume.

**Installing it** (#295): a launchd job runs it every minute, as the `bot` user, from a
LaunchDaemon. [INSTALL.md](INSTALL.md) has the checklist Mari runs, what
`scripts/install.sh` writes, and why the job is a LaunchDaemon.

## Files

| Path | What |
|---|---|
| `bin/pr-notifier` | The CLI: `subscribe`, `unsubscribe`, `status`, `check` |
| `lib/examine.jq` | The filter: one PR's issue timeline and state, turned into wake events |
| `scripts/owner-check.sh` | Vendored from ticket-workflow (#291), below |
| `scripts/pr-notifier-shim.sh` | What the install copies to the stable path |
| `scripts/install.sh` | The install: the shim, the job script, `wake_path`, and the launchd job |
| `scripts/pr-notifier-job.sh` | What launchd runs: keychain, `PATH`, log rotation, then `check` |
| `INSTALL.md` | Mari's install checklist, and why the job is a LaunchDaemon |
| `skills/pr-notifier/SKILL.md` | When sessions call it, and the wake prompt's exact shape |
| `tests/test-pr-notifier.sh` | Tests against stubbed `gh` and `claude` |
| `tests/test-install.sh` | Tests of the install and the job against stubbed `launchctl` and `security` |

## The stable path

Sessions and the launchd job call **`$HOME/.local/bin/pr-notifier`**, never the plugin
cache's own directory, whose name carries the version and changes on every update.
The install (#295) copies `scripts/pr-notifier-shim.sh` there. The shim runs the newest
`pr-notifier/<version>/bin/pr-notifier` it finds under any of the user's config roots
(`~/.claude/plugins/cache/maguerrieri-toolbox/…` and `~/.claude-*/plugins/cache/…`),
so an update needs no reinstall. `PR_NOTIFIER_ROOT` pins a plugin directory instead (a
checkout, or a test). The launchd job runs `"$HOME/.local/bin/pr-notifier" check`, through
the job script the install writes to `~/.local/libexec/pr-notifier-job` ([INSTALL.md](INSTALL.md)).

## State

Everything lives in `$PR_NOTIFIER_HOME`, default `~/.local/state/pr-notifier`, one per
macOS user and shared by all of that user's config roots:

- `registry.json`: the subscriptions. Each records the PR (`owner/repo#n`, lowercased),
  the full session id, the session's name, `CLAUDE_CONFIG_DIR` only if it was set (set
  to `~/.claude` counts as unset: the spike's Trap 3), and `subscribed_at`, two minutes
  before the subscribe so clock skew can't hide a reply that came right after it, and
  the caller's `PATH`, which a resume passes back (*The session's PATH*). No launch dir
  (the spike's *Subscribe: what to record*).
- `state.json`: the feed's cursor (`Last-Modified`, `since`, the next poll time), each
  PR's cursor (timeline items seen, owner checks being retried, tracked comments, last
  sweep, its notification thread's last `updated_at`, and how long its reads have
  failed), cached owner checks, and the events held per session (with any resume or
  relay backoff).
- `config.json`: optional settings (below).
- `notifier.log`: append-only, one line per poll, filtered event (kept or dropped, and
  why), hold, wake, unsubscribe and stale hold. The launchd job rotates it past 1 MiB,
  keeping one old copy as `notifier.log.1`.
- `job.log`, `job.last` and `jq-path`: the launchd job's own output (including
  `check`'s stderr, rotated the same way), its last run's outcome, and the `jq` the
  install found on `wake_path`, which the job reads `config.json` with
  ([INSTALL.md](INSTALL.md)).
- `lock/`: held by any command that writes, so a `subscribe` never races a `check`.
  `subscribe` and `unsubscribe` wait up to five minutes for it; `check` skips its turn
  if it's held. A lock whose holder died, or that has been held over 30 minutes (a dead
  holder whose pid another process now has), is taken over, one contender at a time
  (`lock.takeover/`), so two can't both take it.

Files are replaced atomically (written beside, then moved).

## One check

`check` takes the lock (or logs `check skipped=locked` and exits 0), then:

1. **Poll the feed**, unless `X-Poll-Interval` (60 seconds) hasn't passed since the
   last poll: `GET /notifications?all=true&since=…` with `If-Modified-Since`, so a quiet
   minute is a 304, which the spike found doesn't count against the rate limit. `since`
   moves only on a 200, and at most hourly (to five minutes before that poll, since a
   thread's `updated_at` can trail its event), so the URL usually repeats and a 304
   stays possible, and a restart catches up from the last 200. A thread on a subscribed
   PR marks that PR to be read when its `updated_at` has moved past the one last seen,
   since the same thread comes back on every 200 while `since` holds.
2. **Read every PR that is marked, or due a sweep** (`sweep_interval`, five minutes):
   the PR itself and its issue timeline. The sweep is what makes a missed notification
   harmless. The spike couldn't yet say whether the owner's reviews and line comments
   move the notification thread (its Q4 owner rows wait on Mari's actions on #296), so
   the feed is only the fast path, and every subscribed PR is read on the sweep whether
   or not a notification came. A failed read leaves the PR marked for the next check,
   until it has failed for `hold_bound`: then it's reported once (log and stderr) and
   read only on the sweep, so a PR that's gone, or a ref that was never a PR, costs one
   read per sweep. A good read clears it.
3. **Filter** each new timeline item (below), and queue each kept event for every
   subscription that existed when it happened.
4. **Deliver** what each session has queued (below), one wake per session however many
   events and PRs it covers.
5. **Report** holds older than `hold_bound`.

Rate cost: one feed request a minute, plus two or three requests per subscribed PR per
sweep (the PR, its timeline pages, and owner checks for new logins), and one GraphQL
query for a PR whose comments were edited, all on the token the user's other sessions
share. A relay wake is a short Haiku session on the user's Claude login, $0.0003 to
$0.0009 each.

## The filter

It reads the PR's issue timeline, never the notification, which carries no author and
no event type (the spike's *Filter: read the PR, not the notification*). For each new
`commented`, `reviewed` or `line-commented` item at or after the earliest subscription:

| Actor | Verdict |
|---|---|
| The sessions' own login (`gh api user`, read once per check, as owner-check reads it) | dropped |
| A configured review bot, which GitHub also types `Bot` | kept |
| Any other `Bot`, or a login that isn't a user login's shape | dropped at once |
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
- A review's own line comments can also appear as `line-commented` items; those whose
  review is on the timeline are left to that review, so one review is one event.
- The PR's own state: a merge or a close is kept whoever did it, as `merged` or
  `closed`.
- Codex's clean result edits its old summary comment and adds a 👍, and neither is a
  new timeline item. The filter tracks that comment's `codex-review-state` line and
  keeps the edit as a `review` when it reaches a new completed state. Only a configured
  bot's comment is read this way: the same text in anyone else's comment is an ordinary
  comment, so it can't be forged into a wake.
- **A comment edited by the owner** after the earliest subscription is kept as
  `edited`, whoever wrote it, even if it was posted before, and even while the comment
  itself is still being rechecked (a stranger's, say). The REST timeline names
  only a comment's author, so the notifier asks GraphQL for each edited comment's
  `editor` (one query per PR with edits) and decides the edit by the editor: a write
  collaborator editing the owner's comment wakes nothing. A comment with no record of an
  earlier edit counts as last edited when it was created. **Each edit is decided like a
  new item**: its own owner check (the same cached one) and its own recheck window,
  which an unread editor also gets. No comment pins anyone's ownership, so an admin
  whose access is revoked stops waking sessions once the cache expires, and a failed
  read can't silence a comment's later edits.

## Delivery

Each session is looked up in its own root: `claude agents --json --all` run with the
recorded `CLAUDE_CONFIG_DIR` (unset when it was unset), and its job state at
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/state.json`. Every `claude` call
runs from `/`, without the variables a session sets for what it starts
(`CLAUDE_CODE_SESSION_ID`, its messaging socket and token, and the like), and is killed
after two minutes. It runs under `wake_path`, except a resume, which passes the session's
own `PATH` (below). First match wins:

| State | Action |
|---|---|
| The listing fails | hold |
| No row for the session | hold: a row can come back, and the bound reports it |
| Stopped (no `pid`), and its `cwd` is gone (FINISH removed the worktree) | unsubscribe it, drop its events: its resume would be refused |
| Stopped | `claude --bg --resume <session id> "<wake prompt>"`, with no flag but `--bg` (any other flag starts a copy) |
| `status` `busy` or `waiting`, or `state` `working` | hold |
| Any other live state but idle with `state` `done` or `blocked` | hold |
| Idle with `state` `done` or `blocked` | relay the wake in place (below); if it doesn't land, the fallback |

The fallback, for a live session the relay didn't reach (or with `relay` off, or while
relays to it back off). First match wins:

| State | Action |
|---|---|
| Not a `background` session (a terminal someone is at) | hold: a stop would end it under them |
| Its `cwd` is gone | hold: once stopped, it couldn't be resumed |
| `inFlight` has tasks, queued input or any kind (monitors included), or can't be read | hold |
| Active within `idle_grace` (ten minutes) | hold |
| Otherwise | re-read the row and job state, `claude stop <short id>`, wait until the row shows no `pid`, then resume as above |

- `state` `blocked` with `status` `idle` is a session that handed back waiting on the
  user: the main thing to wake, never a reason to hold.
- **Attached viewers.** The fallback's stop disconnects anyone attached, and attachment
  isn't visible outside Claude Code's daemon. The policy is the idle grace: a live
  session is stopped only after ten minutes without activity, betting that someone
  attached and active keeps it busier than that. The cost when the bet loses is a
  disconnect (and any unsent typing); the conversation itself is kept, and `claude
  attach` reconnects.
- Checking and stopping aren't atomic: a turn can start between the re-read and the
  stop. The re-read narrows that window; it can't close it.
- A refused resume keeps the events, and Claude Code keeps the refused prompt to
  deliver with the next wake. The wake prompt is written so getting it twice is
  harmless, but each retry would queue one more copy, so retries back off: 5, 10, 20
  and 40 minutes, then hourly, until one is accepted.
- **Bounded holds.** Holds rest on Claude Code's internal job state, which can change
  between versions. A session held past `hold_bound` (30 minutes) gets one `stale` log
  line and one stderr line from `check`, and stays held; `status` marks it `STALE`.
- Held events wait in `state.json` until a wake lands, apart from the timeline cursor,
  so a held event never depends on the feed showing its PR again.
- After a wake that carried a `merged` or `closed` event, that PR's subscription for
  the session ends, unless the PR has reopened since (as last read), and the wake's
  `PR` line shows that state.

### The relay

A one-shot headless session sends the wake prompt to the live session, which takes it
as a new turn in the same process: no stop and no fork. Tested on the Mac Studio (#305),
it cost $0.0003 to $0.0009 and about three seconds a wake.

- **How it runs.** `claude -p --safe-mode --name pr-notifier --no-session-persistence
  --model haiku --max-turns 3 --output-format stream-json --verbose --tools
  SendMessage`, in the session's root, with its prompt on stdin: `--tools` takes every
  argument after it, so a prompt there would be read as a tool name. Safe mode loads no
  plugins, hooks or `CLAUDE.md`, and `--no-session-persistence` leaves no transcript.
- **Where it sends.** To the session's own messaging socket,
  `uds:/tmp/cc-socks-<uid>/<pid>.sock` (or the same under `/tmp/cc-socks`), for the
  `pid` its row shows, and only to a socket this user owns. Every live row's `pid` had a
  socket of that name, and a send to one reached that session. A name can be renamed,
  or shared by a forked copy, but a socket can't, so the relay resolves no name and
  needs no `ListAgents` match (the spike's suggestion).
- **Did it send?** The exit code says nothing: `claude -p` exits 0 when the model never
  sends, or rewords the text. So the stream must show exactly one tool call,
  `SendMessage`, to that address, with the wake prompt unchanged, and its tool result
  must say `success: true` with a `msg_id`.
- **Did it land?** A successful send means only that the message reached the session's
  inbox. One held for approval, refused, or sent to a session that has just stopped
  reports the same. So the notifier waits up to `relay_wait` (30 seconds) for the
  session's transcript (`projects/*/<session id>.jsonl` in its root) to show the message
  as a turn: a `user` line whose `origin.msg_id` is the relay's. Only that counts. With no
  transcript to read (should Claude Code move it), the row stands in: the same `pid`,
  turned `busy`. A moved `updatedAt` never counts, since a retire right after the send
  moves it too.
- **When it doesn't land.** `relay-failed` in the log says why, with the session's
  permission mode, read from its transcript's last `permission-mode` line, so a hold by
  a mode mismatch shows there. Relays to that session then back off (5, 10, 20, 40, then
  60 minutes), since an unconfirmed message can still arrive later (a held one,
  approved), and the fallback runs at once.
- **What the session sees.** `Another Claude session sent a message:`, then
  `<cross-session-message from="uds:…" from-name="pr-notifier" from-mode="prompting">`,
  with the wake prompt inside. `from-mode` stayed `prompting` with or without
  `--permission-mode` on the relay, so a relay can't match a receiver's mode. The one
  pair tested, a `prompting` sender and an `auto` receiver (bot's default), delivered.
- **What it doesn't need.** The relay restarts nothing, so neither the session's cwd nor
  its work in flight matters, and an attached viewer should stay connected (not tested
  with someone watching).

### The session's PATH

A resumed session's tool `PATH` is whatever `PATH` its waker passes, for the rest of its
process (the spike's Trap 2), and no other variable crosses a resume. So `subscribe`
records the caller's `PATH`, the session's own, on every subscription of that session,
and a resume passes it back merged with `wake_path`: the recorded entries first, then any
of `wake_path`'s it lacks, absolute entries only, each once. That way a `PATH` recorded
while degraded (by a session once woken under a bare one) can't persist. A subscription
made before #305 has none and resumes under `wake_path` alone. A relay keeps the session's
whole environment, since it restarts nothing.

### Which events wake whom

- **Merges and closes wake every subscribed session, whoever merged.** Every merge seen
  so far was by the sessions' own login (a session's own FINISH, or an EPIC
  coordinator's Step 7), so the actor can't say which session merged. A session that
  merges its own PR isn't woken in practice: it's busy through FINISH, which
  unsubscribes it (Step 3) before its turn ends, and that drops the held merge event. A
  coordinator's merge of a child's PR wakes the child, which runs its own cleanup
  (ticket-workflow's `notifier.md`), harmlessly if the coordinator already did some of
  it.
- **The sessions' own comments and reviews wake no one.** The filter drops the
  sessions' login, and those posts never reach a conditional poll anyway (the spike's
  §4). That includes another session's posts, such as a coordinator's `restack:`
  comment or a `/code-review --comment` finding: every session posts as the one login,
  so the notifier can't tell which one did. Those reach a session by SendMessage, as
  ticket-workflow's messaging does, or when it next reads the PR.
- **A close by the sessions' own login** never reaches the feed either, so the sweep
  finds it, within `sweep_interval`.

## The wake prompt

A fixed template carrying only URLs, specified in `skills/pr-notifier/SKILL.md`, which
is the contract ticket-workflow (#294) codes against. It opens with
`pr-notifier wake v1:`, whether a resume delivers it as the prompt or a relay delivers it
inside a cross-session message.

## Settings

`config.json` in the state directory, every key optional:

| Key | Default | What |
|---|---|---|
| `review_bots` | Copilot (both logins), Codex | Logins that wake when GitHub types them `Bot` |
| `sweep_interval` | `300` | Seconds between reads of each subscribed PR when no notification marks it |
| `retry_window` | `1800` | Seconds an item a failed owner check dropped is checked again |
| `owner_ttl` | `3600` | Seconds an owner check's yes is cached |
| `idle_grace` | `600` | Seconds a live session must be quiet before the fallback stops it |
| `relay` | `true` | `false` sends every live, idle session straight to the fallback |
| `relay_model` | `haiku` | The model the relay runs |
| `relay_wait` | `30` | Seconds a relay waits for its message to show as a turn |
| `hold_bound` | `1800` | Seconds before a held session is reported stale |
| `wake_path` | the notifier's own `PATH` | The `PATH` every `claude` call gets, and the one a resume merges behind the session's own |

The install sets `wake_path` to the user's full login-shell `PATH`, captured once, and
the launchd job runs `check` with it as its own `PATH` too.

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
bash plugins/pr-notifier/tests/test-install.sh
```

They run the CLI against stubbed `gh` and `claude` (and the real vendored
`owner-check.sh` on the `gh` stub), and the install and the job script against stubbed
`launchctl` and `security`, in CI through `.github/workflows/pr-notifier-ci.yml`.

## Not here

- ticket-workflow subscribing at START, handling the wake prompt, and unsubscribing at
  FINISH: #294.
- Typing into a pty-held `claude attach`, the spike's other way to deliver in place. The
  relay does the same without driving the interactive UI, where typed text can land in a
  dialog or collide with someone typing.
- Batching relays (one relay given every live session a check wakes). A relay costs
  $0.0003 to $0.0009 and about three seconds, so it would save little, and it would make
  each session's landed check harder to read.
