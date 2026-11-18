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

**Installing it** (#295): a launchd job runs it every 15 seconds, as the `bot` user, from a
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
| `scripts/install-daemon.sh` | The one root step: writes and loads the LaunchDaemon's plist. Mari runs it from their own checkout |
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
- `state.json`: the feed's cursor (`Last-Modified`, `since`, the next poll time), the
  direct poll's pace (`pr_poll`: its next time, mode, failures, and the GraphQL budget it
  last read), each PR's cursor (timeline items seen, owner checks being retried, tracked
  comments, last sweep, its notification thread's last `updated_at`, the summary the
  direct poll last read, and how long its reads have failed), cached owner checks, and the
  events held per session (with any resume or relay backoff).
- `config.json`: optional settings (below).
- `notifier.log`: append-only. One line per feed poll (once a minute), and only when
  something happens otherwise: the direct poll marking a PR, failing or changing pace, a
  filtered event (kept or dropped, and why), a hold (once when its reason changes, then
  every five minutes it doesn't), a wake, an unsubscribe and a stale hold. A check with
  nothing subscribed logs its skip once an hour. The launchd job rotates it past 1 MiB,
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

The launchd job runs `check` every 15 seconds. `check` takes the lock (or logs `check
skipped=locked` and exits 0), then:

1. **Poll the feed**, unless `X-Poll-Interval` (60 seconds) hasn't passed since the
   last poll: `GET /notifications?all=true&since=…` with `If-Modified-Since`, so a quiet
   minute is a 304, which the spike found doesn't count against the rate limit. `since`
   moves only on a 200, and at most hourly (to five minutes before that poll, since a
   thread's `updated_at` can trail its event), so the URL usually repeats and a 304
   stays possible, and a restart catches up from the last 200. A thread on a subscribed
   PR marks that PR to be read when its `updated_at` has moved past the one last seen,
   since the same thread comes back on every 200 while `since` holds, unless the PR was
   read ten seconds or more after that `updated_at` (`read-already=` in the log): that
   read saw what moved the thread. The feed noticed an event 50 to 100 seconds after
   GitHub recorded it (#349's measurements), so it is now the catch-up path behind the
   next step.
2. **Poll the subscribed PRs directly** (#349, below), unless `pr_poll_interval` (15
   seconds), less three seconds of slack, hasn't passed since the last time: one GraphQL
   query reads a summary of every subscribed PR, and a PR whose summary moved since the
   last one is marked to be read, as the feed marks it.
3. **Read every PR that is marked, or due a sweep** (`sweep_interval`, five minutes):
   the PR itself and its issue timeline. The sweep is what makes a missed notification
   harmless. The spike couldn't yet say whether the owner's reviews and line comments
   move the notification thread (its Q4 owner rows wait on Mari's actions on #296), so
   the feed is only the fast path, and every subscribed PR is read on the sweep whether
   or not a notification came. A failed read leaves the PR marked, retried by the first
   check about a minute later (not every check, which would hammer GitHub through an
   outage), until it has failed for `hold_bound`: then it's reported once (log and stderr) and
   read only on the sweep, so a PR that's gone, or a ref that was never a PR, costs one
   read per sweep. A good read clears it.
4. **Filter** each new timeline item (below), and queue each kept event for every
   subscription that existed when it happened. An event both polls lead to is queued
   once: the PR's cursor records each timeline item it has seen, and a session's held
   events are keyed by PR and item.
5. **Deliver** what each session has queued (below), one wake per session however many
   events and PRs it covers. Every check retries what is held, so a session that goes
   idle gets its events within about 15 seconds.
6. **Report** holds older than `hold_bound`.

### The direct poll

The notifications feed can't be polled more often than once a minute, but a PR can be
read at any time. So every check also reads each subscribed PR's summary, all in one
GraphQL query (one per hundred PRs, batched further only past that), and compares it with
the one it read last:

- the PR's `state`, `updatedAt`, `mergedAt` and `closedAt`;
- its comments' count, and the newest `updatedAt` among them (`comments(first: 1, orderBy:
  {field: UPDATED_AT, direction: DESC})`), which a new comment and an edit of an old one
  both move;
- its reviews' count, and the newest review's id and `updatedAt`. A line comment, and a
  reply in a review thread, is a review of its own (checked on #343: three thread replies
  were three one-comment reviews), so the count moves for those too.

Any change, or a PR with no summary recorded yet, marks the PR, and step 3 reads it. A PR
marked so is marked once more on the next poll, about 15 seconds on: the summary can show
an item a moment before the REST timeline that step 3 reads does, and once its summary is
recorded, an unchanged summary would mark it no more. The second read is long past that
lag, and since it usually comes ten seconds or more after the notification thread moved,
the feed then skips the PR (step 1). The
summary only says which PRs to read now: reading the PR still decides what woke whom,
with the same filter, keys and coalescing as before, so whatever the feed would have
caught is caught the same way, only sooner. What else moves a summary (a push, the
sessions' own comments) costs a read and wakes no one. A PR that doesn't resolve (deleted,
or out of the token's reach) reads null: the query still answers for the others, and
reading the PR is where its failure is reported. The feed and the sweep stay as they
were: they cover a direct poll that failed or was skipped, and anything a summary can't
show.

**Its budget.** Every request on the token counts against one hourly budget, which the
user's sessions share (`gh pr` commands are GraphQL too), so the poll reads `rateLimit`
in the same query and leaves `graphql_reserve` points (1,000) to them. Below about
`graphql_reserve` plus what the rest of the hour would take at full pace, it stretches its
interval to spread what's left above the reserve over the time to the reset; with nothing
left above the reserve, it waits for the reset. A reset it can't read counts as an hour
away. Each PR it marks costs a REST read, a budget of its own, so when it has marked
something it also reads `GET /rate_limit`, which costs nothing: with `rest_reserve`
requests (1,000) or fewer left, it marks nothing and records none of the summaries that
moved, so the next poll marks them once the budget is back (`poll-prs rest-low`, then
`rest-ok`); a budget it can't read keeps the state it had. A failed poll backs off (30 seconds, then a minute, two and four, then every
five minutes, or every `pr_poll_interval` past that) and, when GitHub's hourly limit failed
it, waits past the reset it last read. A secondary limit, which clears in about a minute,
takes the ordinary backoff. Past a hundred PRs, a query that fails leaves the others' at
pace, and is logged at most every five minutes. A subscription whose PR number is past
GraphQL's 32-bit `Int` (a typo `subscribe` accepted) would fail the whole query, so it is
left out, and reading the PR reports it. Each change of pace is one `poll-prs mode=…` line in
the log, and `status` shows the last one.

**Why every 15 seconds, from launchd.** The job's `StartInterval` went from 60 to 15
rather than one run looping inside itself. launchd already keeps what a loop would have
to rebuild: it runs one copy at a time, skips a firing that comes while a run is still
going (so a slow pass delays the next by under 15 seconds and never overlaps it), and
stops the job between runs on a `bootout`, with every state write atomic. A loop would
need its own signal handling, and would have to line its exits up with launchd's firings
or lose one after a slow pass. The cost is the plist change, which Mari installs once with
`install-daemon.sh` ([INSTALL.md](INSTALL.md), *After a plugin update*). Until then the
new code runs every minute, as before, with the direct poll in each run.

**Rate cost.** REST and GraphQL are counted separately, at 5,000 an hour each for a user
token:

| | GraphQL points an hour | REST requests an hour |
|---|---|---|
| The direct poll, 20 PRs | 240 (1 a query, 240 queries) | `GET /rate_limit` when it marks a PR, which costs none |
| The direct poll, 100 PRs | 480 (2 a query) | the same |
| The feed | none | up to 60 (a 304 doesn't count, the spike found) |
| The sweep, 20 PRs | none | about 480 (the PR and its timeline, every five minutes) |
| The sweep, 100 PRs | none | about 2,400 |
| A marked PR | none | 2 or 3 a read (the PR, its timeline pages, owner checks for new logins) |
| An edited comment | 1 a PR read | none |

The query's cost was measured with `rateLimit(dryRun: true)`: 1 point for 20 PRs and 2 for
100. A marked PR costs the same as before; the direct poll marks a PR for any change, the
sessions' own comments and pushes included, and reads it on the check it moves in and on
the next: twice for each move, where the feed read it once for each moved thread. A PR in
a review loop moves perhaps 20 to 60 times an hour (pushes, reviews, one review per thread
reply, comments), about 80 to 360 REST requests; `rest_reserve` bounds the worst case. A relay wake is a short Haiku session on the user's
Claude login, $0.0003 to $0.0009 each.

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
`${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/state.json`. A listing is reused
for at most 15 seconds within a check, since a relay can take a minute and a session that
has started since must not be resumed (that forks it). Every `claude` call runs from `/`, without the variables a session sets for what it starts
(`CLAUDE_CODE_SESSION_ID`, its messaging socket and token, and the like), and is killed
after two minutes. It runs under `wake_path`, except a resume, which passes the session's
own `PATH` (below). **`/` must stay untrusted** ([*Resumes and copies*](#resumes-and-copies), below). First match wins:

| State | Action |
|---|---|
| The listing fails | hold |
| No row for the session | hold, since a row can come back. Once it has had none for `hold_bound` (30 minutes), unsubscribe it, drop its events, and comment on each of its PRs that it's no longer listening, naming it only by its short id (the PR may be public; the log has its full id and the command that resubscribes it): a session deleted from agent view (Ctrl-X) or by `claude rm` leaves no row, and can't be woken. A row seen in between starts the bound over. Unless the listing looks broken: when it shows no session at all, or every other session subscribed in the same root has gone missing too, a changed or broken listing (a Claude Code update, say) is likelier than deletions, so they stay held |
| Stopped (no `pid`), and its `cwd` is gone (FINISH removed the worktree) | unsubscribe it, drop its events: its resume would be refused |
| Stopped | read its row afresh, since the listing can be seconds old: still stopped, `claude --bg --resume <session id> "<wake prompt>"`, with no flag but `--bg` (any other flag starts a copy); started since, hold for the next check, since resuming a live session forks it |
| `status` `idle` and `state` `working`, nothing in `inFlight`, the job's `tempo` `idle`, and no job state written for `working_grace` (two minutes) | treat it as idle (the last row), and log `stale-state` once a hold: no turn is running |
| `status` `busy` or `waiting`, or `state` `working` | hold |
| Any other live state but idle with `state` `done` or `blocked` | hold |
| Idle with `state` `done` or `blocked` | relay the wake in place (below); if it doesn't land, the fallback |

The fallback, for a live session the relay didn't reach: the relay wasn't sent, or one
sent a check ago never became a turn, or relays are off, backing off, or have given up.
First match wins:

| State | Action |
|---|---|
| Not a `background` session (a terminal someone is at) | hold: a stop would end it under them |
| Its `cwd` is gone | hold: once stopped, it couldn't be resumed |
| `inFlight` has tasks, queued input or any kind (monitors included), or can't be read | hold |
| Active within `idle_grace` (ten minutes) | hold |
| Otherwise | re-read the row and job state (still idle, as above), `claude stop <short id>`, wait until the worker process the row named has exited (up to five seconds), then until a fresh row shows no `pid`, then resume as above. A worker still running after five seconds is recorded, and the stopped path holds the session while that pid exists (for up to ten minutes, so a pid another process takes later can't hold it for good) |

- `state` `blocked` with `status` `idle` is a session that handed back waiting on the
  user: the main thing to wake, never a reason to hold.
- `state` `working` with `status` `idle` can be left over. A session stopped while
  `blocked` and then woken with no prompt (attached to from agent view, say) comes back
  reading `working`, idle, with nothing in flight and its job's `tempo` `idle`, and stays
  so (reproduced on 2.1.325, #338). It is at its prompt and takes a relay as an idle one
  does, so once its job state has been quiet for `working_grace` it isn't held. Before
  #338 it was held as busy until the hold bound. A running turn read `status` `busy` and
  `tempo` `active`, and writes its job state as it goes. Anything else (a `tempo` other
  than `idle`, or a job state that can't be read) still holds, since a turn can't be
  ruled out. The relay and the fallback's re-read decide this the same way.
- **Attached viewers.** The fallback's stop disconnects anyone attached, and attachment
  isn't visible outside Claude Code's daemon. The policy is the idle grace: a live
  session is stopped only after ten minutes without activity, betting that someone
  attached and active keeps it busier than that. The cost when the bet loses is a
  disconnect (and any unsent typing); the conversation itself is kept, and `claude
  attach` reconnects.
- Checking and stopping aren't atomic: a turn can start between the re-read and the
  stop. The re-read narrows that window; it can't close it.
- A refused resume keeps the events, and retries back off: 5, 10, 20 and 40 minutes,
  then hourly, until one is accepted. One refused for the session's own cwd (untrusted,
  or gone) says its message is saved for the session's next start (the #292 spike), so
  a retry can deliver the prompt twice: the wake prompt is written so that's harmless,
  and the backoff keeps copies from piling up. One refused because it would have started
  a copy (next) keeps nothing.
- <a id="resumes-and-copies"></a>**Resumes and copies.** `claude --bg --resume <id>` wakes a
  session only once Claude Code's daemon counts it as stopped: the daemon then runs it in
  its own recorded cwd and says `woke session <id> with its saved options`. To a session
  the daemon still counts as running, the same command starts a copy (`session <id> is
  already running in the background, so this started a copy as <new id>`), a fork of the
  conversation, in the caller's cwd. The daemon counts a stopped session as running until
  its worker process exits: `claude stop` returned in about 0.4 seconds with the worker
  still running, and the row lost its `pid` at once, but the worker exited 0.4 to 0.7
  seconds later, and the daemon settled the session as it did (2.1.325, #338). Before
  #338 the fallback resumed as soon as the row lost its `pid`. So every first wake
  started a copy, the trust check refused it from `/` (`Workspace not trusted. Run
  claude in / once and accept the trust prompt`), and the retry five minutes later, by
  then a wake, landed. The fallback now waits for the worker itself. **Don't accept that
  trust prompt in `/`, whatever the log says**: from a trusted cwd (`/`, or the
  session's own) the copy runs, with the wake prompt, beside the session it copied. A
  resume whose output carries that note anyway is no wake: the copy is stopped at once,
  with one retry a second on (its conversation is kept), the events stay held, and
  `check` logs `wake-forked` and says so on stderr. Only the note counts, since a real
  wake never prints it; guessing from less (a `backgrounded ·` line's id, say) could stop
  the session a real wake had just started. The note is 2.1.325's wording, so this is a
  backstop: `/` staying untrusted is the guard, and `install.sh status` warns when any
  config root trusts it.
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
  plugins, hooks or `CLAUDE.md`, and `--no-session-persistence` leaves no transcript. A
  relay is killed after a minute. Every relay, stop and resume holds the lock that
  `subscribe` waits only five minutes for, so no delivery starts once a check's deliveries
  have run 150 seconds (the poll and the PR reads before them don't count): the rest are
  held for the next check. Sessions take turns going first, one place a check, so a few
  slow ones can't use up the budget every time and leave the rest unreached.
- **Where it sends.** To the session's own messaging socket, `<pid>.sock` for the `pid`
  its row shows, in `/tmp/cc-socks` when that directory is this user's or root's and
  private, else in `/tmp/cc-socks-<uid>`, as Claude Code places them. A directory or socket
  someone else could have placed (another owner, writable by others, a symlink) is
  skipped, and the socket must be this user's. Every live row's `pid` had a socket of that
  name, and a send to one reached that session. A name can be renamed,
  or shared by a forked copy, but a socket can't, so the relay resolves no name and
  needs no `ListAgents` match (the spike's suggestion).
- **Did it send?** The exit code says nothing: `claude -p` exits 0 when the model never
  sends, or rewords the text. So the stream must show a `SendMessage` call to that address
  whose tool result says `success: true` with a `msg_id`, the wake prompt unchanged. When
  the relay retries after a send that failed, the last one that succeeded decides.
- **Did it land?** A successful send means only that the message reached the session's
  inbox. One held for approval, refused, or sent to a session that has just stopped
  reports the same. So the notifier waits up to `relay_wait` (30 seconds) for the
  session's transcript (`projects/*/<session id>.jsonl` in its root) to show the message
  as a turn: a `user` line whose `origin.msg_id` is the relay's. Only that counts. With no
  transcript to read (should Claude Code move it), the row stands in, read every two
  seconds: the same `pid`, turned `busy`. A moved `updatedAt` never counts, since a retire right after the send
  moves it too.
- **When it doesn't land.** `relay-failed` in the log says why, with the session's
  permission mode, read from its transcript's last `permission-mode` line, so a hold by
  a mode mismatch shows there. A relay that sent nothing to the session (no tool call,
  another tool or address, a send that failed) falls back at once. One whose message may
  have reached it (sent but not yet a turn, sent with the text changed, or killed before
  its result) may still be taken, so the session is held, and the fallback waits a
  minute, what was one check before checks ran every 15 seconds. Each message sent but not yet taken is remembered with the events
  it carried, since a retry doesn't stop the session taking an earlier one, and every
  later check looks for each in the transcript first: once the session has taken one,
  those of its events still held count as delivered (`wake … how=relay-late`), and the
  events left start a hold of their own. Either way, relays to that session then back off
  (5, 10, 20, 40, then 60 minutes). After three relays that may have reached it without
  landing, the notifier stops relaying to it until a wake lands or a new event arrives,
  since a terminal session, whose fallback only holds, would otherwise get one an hour.
  And with five still unconfirmed, it stops until one lands, however many new events
  arrive, so a session holding peer messages for approval never gets more than five.
  Relays that sent nothing (a crash, a missing socket) only back off, so they never stop
  relays for good.
- **What the session sees.** `Another Claude session sent a message:`, then
  `<cross-session-message from="uds:…" from-name="pr-notifier" from-mode="prompting">`,
  with the wake prompt inside. `from-mode` stayed `prompting` with or without
  `--permission-mode` on the relay, so a relay can't match a receiver's mode. The one
  pair tested, a `prompting` sender and an `auto` receiver (bot's default), delivered.
- **What it doesn't need.** The relay restarts nothing, so neither the session's cwd nor
  its work in flight matters, and an attached viewer should stay connected (not tested
  with someone watching). A terminal session gets the relay too: the message starts a turn
  of its own, as any peer's message does, and nothing is typed into its input.

### The session's PATH

A resumed session's tool `PATH` is whatever `PATH` its waker passes, for the rest of its
process (the spike's Trap 2), and no other variable crosses a resume. So when a session
runs `subscribe` itself, it records the caller's `PATH`, the session's own, on every
subscription of that session. A subscribe for another session (`--session` from a shell)
records none and keeps what's there. A resume passes it back merged with `wake_path`: the recorded entries first, then any
of `wake_path`'s it lacks, absolute entries only, each once. That way a `PATH` recorded
while degraded (by a session once woken under a bare one) can't persist. A subscription
made before #305 has none and resumes under `wake_path` alone. A relay keeps the session's
whole environment, since it restarts nothing.

### Which events wake whom

- **Merges and closes wake every subscribed session, whoever merged.** Every merge seen
  so far was by the sessions' own login (a session's own FINISH, or an EPIC
  coordinator's Step 7), so the actor can't say which session merged. A session that
  merges its own PR isn't woken in practice: it's busy through FINISH, which
  unsubscribes it (Step 3) before its turn ends, and that drops the held merge event.
  An EPIC coordinator that lands a local child's PR and removes its worktree unsubscribes
  the child first (FINISH Step 2), so the child isn't woken either. A merge that leaves
  the cleanup to the child (a stacked PR landed from the owner's session) does wake it,
  and it runs that cleanup (ticket-workflow's `notifier.md`).
- **The sessions' own comments and reviews wake no one.** The filter drops the
  sessions' login, and those posts never reach a conditional poll anyway (the spike's
  §4). That includes another session's posts, such as a coordinator's `restack:`
  comment or a `/code-review --comment` finding: every session posts as the one login,
  so the notifier can't tell which one did. Those reach a session by SendMessage, as
  ticket-workflow's messaging does, or when it next reads the PR.
- **A close by the sessions' own login** never reaches the feed either. The direct poll
  sees the PR's state change on the next check, and the sweep finds it within
  `sweep_interval` should that poll fail.

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
| `pr_poll` | `true` | `false` turns the direct poll off, leaving the feed and the sweep |
| `pr_poll_interval` | `15` | Seconds between direct polls (at least 5), less three seconds of slack for launchd's firings. The job fires every 15 seconds, so the pace rounds to its firings: up to 18 polls every 15 seconds, 19 to 33 every 30, and so on. Above 18 it slows the poll without a new plist |
| `graphql_reserve` | `1000` | GraphQL points of the hourly budget the direct poll leaves to the sessions: it slows down to stay above them, and waits for the reset at them |
| `rest_reserve` | `1000` | REST requests of the hourly budget the direct poll leaves: at or below it, the poll marks no PR to be read, and the feed and the sweep carry on |
| `sweep_interval` | `300` | Seconds between reads of each subscribed PR when no notification marks it |
| `retry_window` | `1800` | Seconds an item a failed owner check dropped is checked again |
| `owner_ttl` | `3600` | Seconds an owner check's yes is cached |
| `idle_grace` | `600` | Seconds a live session must be quiet before the fallback stops it |
| `working_grace` | `120` | Seconds an idle session still reading `state` `working`, with nothing in flight, must go without a job state write before it's treated as idle |
| `relay` | `true` | `false` sends every live, idle session straight to the fallback |
| `relay_model` | `haiku` | The model the relay runs |
| `relay_wait` | `30` | Seconds a relay waits for its message to show as a turn |
| `hold_bound` | `1800` | Seconds before a held session is reported stale, and before one with no row is unsubscribed |
| `drop_comment` | `true` | `false` unsubscribes a session with no row without commenting on its PRs |
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
`launchctl` and `security`, in CI through `.github/workflows/pr-notifier-ci.yml`. The
install tests also run there on macOS, under its own `/bin/bash` 3.2.

## Not here

- ticket-workflow subscribing at START, handling the wake prompt, and unsubscribing at
  FINISH: #294.
- Typing into a pty-held `claude attach`, the spike's other way to deliver in place. The
  relay does the same without driving the interactive UI, where typed text can land in a
  dialog or mix with what someone is typing: a relayed message starts its own turn.
- Batching relays (one relay given every live session a check wakes). A relay costs
  $0.0003 to $0.0009 and about three seconds, so it would save little, and it would make
  each session's landed check harder to read.
