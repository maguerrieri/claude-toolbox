# PR notifier spike: findings

**Date:** 2026-10-31
**Issue:** #292, child 1 of epic #290 (the PR notifier)
**Where:** the Mac Studio, as the `bot` macOS user (uid 502), Claude Code 2.1.316, `gh` as `sprue-works-bot`
**Status:** findings; children 2–4 (#293, #294, #295) build on the *Design corrections* at the end

Each question from #292 is answered below with how it was found: **tested** (run on this
machine), **read** (read from the Claude Code 2.1.316 binary's bundled JavaScript, via
`strings`; minified names are quoted as found and will change between versions), or
**untested** (with the reason). Test sessions were cheap Haiku sessions named `spike-292 …`;
the notification target was the throwaway PR #296. Timestamps are UTC.

## Summary

| # | Question | Answer |
|---|---|---|
| 1 | Idle stop | Yes. An unbridged session is stopped after **1 hour** idle (tested). Every `bot` session is Remote Control-bridged (`remoteControlAtStartup: true`), and a bridged session gets **8 hours** (read; a bridged test session was still live after 5 hours, and the 8-hour mark wasn't observed). Attached and pinned sessions, and ones with work in flight, are skipped. The exception is **memory pressure**: then the limit drops to 60 seconds, bridged or not, and sessions holding only monitors, then pinned ones, can go too. |
| 2 | Resume from launchd | Works from a real launchd job in `user/502` and from `env -i`, with no TTY and no direnv, and keeps the id, name and row (tested). Four traps: **any flag other than `--bg` next to `--resume` starts a copy**; **the job's `PATH` becomes the woken session's tool `PATH`**; **`CLAUDE_CONFIG_DIR=~/.claude` set explicitly isn't the default root**; and **a session whose cwd is gone can't be resumed**. The last two are refused with exit 1. Untested: a locked keychain, and a LaunchDaemon (maguerrieri/config#47's route). |
| 3 | Waking a live, idle session | `--resume` on a live session **forks a copy**; `claude respawn` restarts it but **takes no prompt**. What works: `claude stop` then `--resume` (context kept; an attached viewer is disconnected), or typing into a pty-held `claude attach` (in place, but fragile). (tested) |
| 4 | Which notifications arrive | Copilot's and Codex's reviews reach the feed, as `reason: author`. The feed's `updated_at` trailed each event by up to 20 seconds, and the 60-second poll saw them 17–50 seconds after the event. The bot's own posts don't appear. `X-Poll-Interval` is 60, and a 304 doesn't appear to count against the rate limit. **The owner-side events (Mari's comments, reviews, a merge) are still pending**, waiting on Mari's actions on #296. (tested; owner rows pending) |
| 5 | Harness PR events in a local session | **No.** The subscription tool exists only on the cloud harness's MCP server; `ReadNotifications` stayed empty through all of #296's activity. The epic does not need rescoping. (tested + read) |

## 1. The idle stop

**Mechanism (read).** The background daemon (`claude daemon run`, its log at
`~/.claude/daemon.log`) sweeps every 60 seconds (`xe=60000`) and calls each worker's
`retireIfSettled(he, pinned, pe)`. A worker is skipped when any of these hold:

- someone is attached (`attachers.size>0` → `reason:"attached"`);
- it is pinned (its short id is in `~/.claude/jobs/pins.json` → `"pinned"`);
- it was adopted after a daemon restart, or had input, within the grace period;
- it has work in flight: background Bash or agents (`inFlight.tasks`), queued input, a
  session cron (`"session-cron"`, what `CronCreate` arms), or a routine.

Otherwise a settled session (idle, or ended its turn waiting on the user) is retired once
its `updatedAt` is older than the threshold: **1 hour** (`pr=3600000`), or **8 hours** when
the session is bridged to claude.ai by Remote Control (`O=o.bridgeSessionId?Math.max(e,s):e`,
with `s` = `fr=28800000`).

Memory pressure (macOS memory-status pressure, or little free memory) changes that, and only
then do these passes run:
1. Both thresholds drop to 60 seconds (`Qe=60000`).
2. If that sweep retires nothing, a second pass retires sessions whose only work in flight
   is monitors, once they've been idle 8 hours (`shedMonitoringOnly`, `bt=28800000`).
3. If pressure persists after that, pinned sessions go too ("retiring pinned settled
   workers as a last resort").

A retire logs `bg retire <id>: <cause>, idle <n>m` and `bg settled <id> (done)`.

**bot's sessions are all bridged.** `~/.claude/settings.json` sets
`remoteControlAtStartup: true`, and every job under `~/.claude/jobs/` has a
`bridgeSessionId`. So a bot session waits **8 hours** idle, not about one, before it is
stopped. That holds only while the job has a `bridgeSessionId`. A session whose Remote
Control link never came up presumably has none and gets the hour (untested). The daemon log agrees: `2ad34855` sat idle for 409 minutes (08:42–15:31) with no
retire, while the only `idle 60m` retires were `stale-spare` ones (a spare process claimed
by a session that never wrote job state).

**Test.** Three sessions launched at 17:18:45–17:18:51, each answering one word and then
idle: `e71c5d32` (bridged, the default), and `330343df` and `f65c5d81` (launched with
`--settings '{"remoteControlAtStartup": false}'`, so unbridged). Their job state last
changed at 17:18:49–17:18:54. The two unbridged ones were retired at 18:19:16, 60 minutes
22 seconds later, on the first sweep past the hour:

```
[2026-10-31T18:19:16.111Z] [bg] bg retire 330343df: settled, idle 60m
[2026-10-31T18:19:16.113Z] [bg] bg retire f65c5d81: settled, idle 60m
[2026-10-31T18:19:16.200Z] [bg] bg settled f65c5d81 (done)
[2026-10-31T18:19:16.200Z] [bg] bg settled 330343df (done)
```

The bridged one was still live at 22:19, five hours idle. The spike didn't run to its
eight-hour mark. (`f65c5d81` was meant to be pinned as well; see *Pinning* for why it
wasn't, so it is a second unpinned sample.)

**After a stop or a retire**, `claude agents --json --all` keeps the row with its last
`state` (`done` or `blocked`) and sets `status` and `pid` to `null`. The job directory stays,
so the session can be resumed:

```json
{"id":"0f43a5bc","name":"spike-292 resume T4","state":"done","status":null,"pid":null}
```

**Pinning.** The CLI has no pin command. Agent view's Ctrl+T toggles the short id in
`~/.claude/jobs/pins.json` (a JSON array of short ids), and the sweep skips those (read).
Untested: writing `pins.json` from this session was refused by the auto-mode permission
classifier, and I didn't work around it. To check it by hand, pin a test session in agent
view and confirm it outlives the threshold.

## 2. Resume from launchd's environment

**A real launchd job works without root.** `gui/502` doesn't exist (bot has no GUI login),
but `user/502` does (`session = Background`). `launchctl bootstrap user/502 <plist>` failed
with `Bootstrap failed: 5: Input/output error` until the plist said
`LimitLoadToSessionType = Background`; then it loaded, ran once (`RunAtLoad`), and exited 0.
The plist lived in the job's temp directory, not `~/Library/LaunchAgents`, and was booted
out afterwards. Its job ran, from `WorkingDirectory` `/Users/bot`:

```
/opt/homebrew/bin/claude --bg --resume 0f43a5bc-bd86-4d9c-b1d0-510e38ca2123 "<prompt>"
```

with `PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin` and a marker variable. Output:

```
note: woke session 0f43a5bc with its saved options (-n, --model).
backgrounded · 0f43a5bc · spike-292 resume T4
```

The prompt reached the session 1.5 seconds after the job loaded. The session kept its id,
name and `claude agents` row (new `pid`), and its own cwd: the job's `WorkingDirectory`
doesn't matter. The same held from `env -i` with only `HOME`, `USER`, `LOGNAME`, `SHELL` and
`PATH` set, no TTY, stdin from `/dev/null`, and no direnv.

**Trap 1: any flag other than `--bg` next to `--resume` starts a copy.** `--bg` itself is
needed, since it makes the resume a background session. With `--model haiku` added as well:

```
note: background session 0f43a5bc keeps its own saved options, so the flags you passed started a copy as 095d8a50. Without flags, the same command continues 0f43a5bc itself.
```

**Trap 2: the job's `PATH` becomes the woken session's tool `PATH`.** The session's Bash
tool printed exactly the launcher's `PATH`: with launchd's default
(`/usr/bin:/bin:/usr/sbin:/sbin`), `command -v gh` found nothing; with `/opt/homebrew/bin`
prepended, it found `/opt/homebrew/bin/gh`. Other variables from the job didn't reach the
session (the marker read `unset`), and `TERM` and `LANG` came from the daemon. `ps eww` on
the session process shows the daemon's `PATH`, so the client's `PATH` is applied inside the
process. It lasts for the rest of that process's life, so a session woken with a bare
`PATH` stays unable to run `gh` until it is restarted.

**Trap 3: `CLAUDE_CONFIG_DIR=~/.claude` is not the default.** Unset, Claude reads
`~/.claude.json`; set, it reads `$CLAUDE_CONFIG_DIR/.claude.json`. Setting it to `~/.claude`
explicitly made the resume run without the default root's trust records:

```
Claude configuration file not found at: /Users/bot/.claude/.claude.json
A backup file exists at: /Users/bot/.claude/backups/.claude.json.backup.1793467416479
...
Workspace not trusted. Run `claude` in /Users/bot/Developer/claude-toolbox/.claude/worktrees/epic-290-292 once and accept the trust prompt, then retry. Your message is saved and will be delivered when session 0f43a5bc next starts.
exit=1
```

It also created a stub `~/.claude/.claude.json` holding only a fresh `userID` (removed
afterwards). The refused prompt was kept: the next successful wake delivered it merged into
its own prompt. So a retried wake can arrive twice.

**Trap 4: the session's own cwd must still exist.** The waker's cwd doesn't matter, but the
session's does. A test session (`9ac0bf40`) was launched in a scratch directory and stopped.
Then the directory was renamed away and the session resumed:

```
Workspace not trusted. /Users/bot/Developer/claude-toolbox/.claude/worktrees/epic-290-292/.spike-cwd-test could not be resolved on disk. Your message is saved and will be delivered when session 9ac0bf40 next starts.
exit=1
```

The session stayed stopped. A session's `claude agents` row `cwd` follows `EnterWorktree`:
this session was launched in the main checkout, and its row shows its worktree. So once FINISH
removes a session's worktree, the session can't be woken at all.

**Untested:**

- **A locked keychain.** Locking bot's keychain would cut off every running bot session,
  and I can't unlock it again (no password), so I didn't. What I could see: the daemon
  refreshes the OAuth login itself (`auth: proactive refresh` in its log), and a resume
  hands off to the running daemon, so a resume may not touch the keychain at all while the
  daemon runs. What fails after a reboot with the keychain locked is maguerrieri/config#66's
  question. Test it there: lock, run the job, read its stderr.
- **A LaunchDaemon.** maguerrieri/config#47 installs bot's jobs as LaunchDaemons with
  `UserName bot`. Loading one needs root, so this spike couldn't. Whether
  `claude --bg --resume` works from that context is untested: there may be no `user/502`
  session, and keychain access may differ.
- **No daemon running.** Stopping the daemon stops every bot session, so I didn't. From the
  log, the first `claude` client starts a transient daemon (`origin=transient`,
  `--spawned-by {"label":"claude agents",…}`), which then forks the spare processes. If the
  notifier's job is the first `claude` after a reboot, the daemon starts in the job's
  environment.

## 3. Waking a live, idle session

Tested on `0f43a5bc` while it was live and idle:

- **`claude --bg --resume <id> "<prompt>"` forks.** It printed
  `note: session 0f43a5bc is already running in the background, so this started a copy as a4b9ecdc.`
  The copy is a new session with its own id; the original never sees the prompt.
- **`claude respawn <id>` can't carry a prompt.** It printed
  `warning: extra arguments ignored: …` and `respawned 0f43a5bc`, restarted the process
  under the same id, and left it idle with no new turn. It exists to move a session to the
  current binary.
- **`claude stop <id>`, then `claude --bg --resume <id> "<prompt>"` works.** The
  conversation continues in the same transcript: the woken session answered with the earlier
  turns in view. The stop kills the process, so anything in flight goes with it (background
  Bash, monitors, session crons). An attached viewer (held open under a pty to stand in for
  Mari) was disconnected at the stop and printed
  `Session 0f43a5bc has exited — run claude attach 0f43a5bc to resume it.`; it does not
  reattach by itself.
- **Typing into a pty-held `claude attach` delivers in place.** A script opened
  `claude attach 0f43a5bc` under a pty, typed a prompt and Enter, and closed: the session
  answered in the same process (same `pid`), with no stop. It works, but it drives the
  interactive UI: text typed while a permission dialog or a menu is open lands there, and
  it can collide with what an attached person is typing.

**Attachment isn't visible from outside.** `claude agents --json` has no attached field;
only the daemon knows (`attachers`). So a notifier can't tell whether Mari is watching.

**Which states are safe to wake.** In `claude agents --json`, `state: "blocked"` with
`status: "idle"` means the session **ended its turn waiting on the user** (its job state has
`tempo: "blocked"` and a `needs` text such as `Mari, merge #78 and #145, and review #79`).
That's the usual hand-back state, so it's a prime wake target, not one to hold. A session
stopped mid-turn on something else, such as a permission prompt, keeps `state: "working"`
(read: the retire code treats `tempo: "blocked"` with any `state` other than `blocked` as
mid-turn).

## 4. Which notifications arrive, and how fast

`GET /notifications` works with bot's classic OAuth token (`X-Oauth-Scopes: gist, read:org,
repo, workflow`; `X-Accepted-Oauth-Scopes: notifications, repo`). A poller ran through the
spike (`all=true`, `If-Modified-Since`, honoring `X-Poll-Interval`) and logged every thread
change; event times come from each PR's timeline.

- **`X-Poll-Interval: 60`** on every response.
- **A 304 doesn't appear to count against the rate limit.** At 22:23, with bot quiet, 20
  conditional requests in a row all returned `304 Not Modified`. In their own headers, 19
  reported `X-RateLimit-Used: 55` and one reported 54. Had each counted, `used` would have
  climbed by about 20. It moved by one somewhere in the run, from a cause not identified;
  every bot session shares the token's 5,000/hour. An earlier run during busy minutes saw
  ten 304s move it by one too. GitHub's REST docs say a 304 for an authorized conditional
  request doesn't count against the primary rate limit.
- **Latency.** The feed's `updated_at` trailed each event by 0–20 seconds. The 60-second
  poll then saw the events 17–50 seconds after they happened, and a poll that just missed
  one would see it up to about 80 seconds later.
- **Busy minutes return 200, quiet ones 304.** Of the 299 polls from 17:17 to 22:17, 15
  returned 200, all between 17:17 and 17:36 while about ten bot PRs were active; once bot's
  sessions went quiet, every poll was a 304. One request a minute is 60 of the 5,000/hour
  either way.
- **The bot's own posts don't appear.** A comment by `sprue-works-bot` on #296 at 17:30:20
  left the thread's `updated_at` unchanged.
- **A notification says when, not what.** A thread carries `reason`, `updated_at`,
  `subject.url` and `subject.latest_comment_url`. Its `updated_at` also moves for events that
  aren't comments: Codex's 👍 reaction moved it with `latest_comment_url` unchanged.

| Event on bot PR #296 | At | In feed? | `reason` | `updated_at` | Seen by poller | `latest_comment_url` |
|---|---|---|---|---|---|---|
| Copilot review (an *unable to review* body; ruleset auto-request on the draft) | 17:17:15 | yes | `author` | 17:17:35 | 17:18:05 | none |
| Codex summary comment (after *ready for review*) | 17:18:30 | yes | `author` | 17:18:36 | 17:19:05 | the Codex comment |
| Codex 👍 reaction (review done, no findings) | 17:19:49 | yes | `author` | 17:19:49 | 17:20:06 | unchanged |
| Bot's own comment | 17:30:20 | **no** | | | | |
| Mari: top-level comment | pending | | | | | |
| Mari: line comment | pending | | | | | |
| Mari: review, comment | pending | | | | | |
| Mari: review, request changes | pending | | | | | |
| Mari: review, approve | pending | | | | | |
| Merge (Mari, on any bot PR) | pending | | | | | |
| Close (by the bot itself) | pending | | | | | |

**The owner-side rows are pending.** They need Mari's own account. The actions were requested
on #296 at 17:18 ([the checklist](https://github.com/maguerrieri/claude-toolbox/pull/296#issuecomment-6546644542)),
and none had happened by 22:19. No bot PR was merged in that window either. The poller keeps
running, and these rows get filled in when the events land. The close waits until then too,
because closing #296 would end Mari's test. Going by the bot's own comment above, a close by
the bot is expected not to appear.

**Review bots on bot PRs today.** Copilot's ruleset auto-request fires even on a draft.
Codex reviews when a PR is opened for review, when a draft is marked ready (not on a draft),
on new commits to a PR it reviews (its summary's *Review trigger* column read `New commits`
for #298's second head), or on `@codex review`. On a clean review it edits one summary comment
(`<!-- codex-pull-request-review-summary -->`, with a `codex-review-state` JSON line) and adds
a 👍.

Copilot ran out of quota for bot between 17:10:29 (its last full review, on
maguerrieri/claude-config#147) and 17:13:19. Every Copilot review since then has read
*Copilot was unable to review this pull request because the user who requested the review
has insufficient remaining quota.*:
- maguerrieri/toolbox#860 at 17:13:19;
- maguerrieri/claude-config#147 at 17:16:19;
- maguerrieri/toolbox#861 at 17:16:48;
- #296 at 17:17:15;
- this spike's PR, #298, at 22:26:30 and 22:28:17.

## 5. Do harness PR events reach a local session?

**No.**

- **Nothing arrived.** This session is a local `--bg` session (bridged). Its
  `ReadNotifications` returned `No queued notifications.` after Copilot's and Codex's reviews
  and the comments on #296, and again at 22:19.
- **A local session can't subscribe.** The subscription tool, `subscribe_pr_activity` (and
  `unsubscribe_pr_activity`), is served by the `claude-code-remote` MCP server, whose
  endpoint is `/v2/ccr-sessions/-/meta/mcp`. The binary attaches that server for cloud (CCR)
  sessions. A local session's tool list has no copy of it, and the `github` plugin's MCP
  server, the other place the binary looks for it, fails to connect for bot
  (`Authorization header is badly formatted`).
- **Leads not pursued.**
  - A bridged session has a *session inbox*: Remote Control relays a message typed in its
    claude.ai chat thread (`FetchInboxMessage`). No CLI writes to it.
  - The `RemoteTrigger` tool can attach a GitHub webhook trigger to a routine, but routines
    run as cloud sessions (`job_config.ccr`).

  Neither is a channel a local program can use today.

## Design corrections for #290

What the answers do to the epic's sketch, section by section.

**Subscribe: what to record.**
- The full session id, which `--resume` takes, and the name. The id's first 8 characters
  are the short id that names the job directory (`e71c5d32` for `e71c5d32-20dd-…`).
- `CLAUDE_CONFIG_DIR`, **only if it is set**. Wake with it unset when it was unset, because
  setting `~/.claude` explicitly breaks the default root (Trap 3).
- **Not the launch dir.** The waker's cwd doesn't matter. What matters is the session's own
  cwd (Trap 4), and that moves with `EnterWorktree`. So read it from the session's
  `claude agents` row at wake time, not at subscribe.
- **Not a per-session `PATH`.** Whatever `PATH` the waker passes becomes the woken session's
  tool `PATH` for the rest of its process's life (Trap 2). A `PATH` captured in the
  session's Bash tool could also carry a worktree's direnv additions. Use one full `PATH`
  that the install sets: bot's login-shell `PATH`, captured at install time.

**Poll: confirmed.**
- `If-Modified-Since` works, a 304 doesn't appear to count against the rate limit, and
  `X-Poll-Interval` is 60.
- Expect 200s while bot is busy and 304s when it's quiet. Either way it's cheap.
- With a 60-second poll, plan for a wake up to about 80 seconds after the event, plus the
  wake itself.
- Use a classic token with `repo` or `notifications` scope, as bot's `gh` login has.
  GitHub's REST docs say fine-grained and GitHub App tokens can't read this endpoint (not
  tested).

**Filter: read the PR, not the notification.** A thread change carries no author and no
event type, and its `updated_at` also moves for edits and reactions. So for each changed
subscribed PR:
- Read what happened since the last wake from the PR's issue timeline
  (`GET /repos/{owner}/{repo}/issues/{n}/timeline`). It lists comments, reviews (a single
  line comment is a review too), and `merged` and `closed` events, each with its actor.
- Check the PR's own state as well. A merge or a close is a wake whatever else the timeline
  shows.
- Codex's clean result is an edit of its old summary comment plus a 👍, and neither is a new
  timeline item. Catch it by the summary comment's `updated_at`, or the commit in its
  `codex-review-state` line, changing. Then decide whether it wakes the session: it's the
  review a session waits on.
- Apply the owner and review-bot checks to each actor, and drop the bot's own items. The
  bot's own posts never reach its feed, but its items do appear in the timeline.
- Still open until Mari's events land: whether owner reviews and line comments each move the
  thread, and with which `reason`.

**Deliver: the state table changes.**

Look each session up in its own root:
- run `claude agents --json --all` with the recorded `CLAUDE_CONFIG_DIR`, unset if it was
  unset;
- read its job state at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/state.json`.

Then, first match wins:

| State | Action |
|---|---|
| The row's `cwd` no longer exists | Don't resume: it is refused (exit 1) and the prompt is queued. Usually FINISH removed the worktree. Unsubscribe and log it. |
| Stopped: `pid: null` | `claude --bg --resume <session id> "<wake prompt>"`, with **no flag but `--bg`**. Run it from any cwd, with the install's `PATH` and the recorded `CLAUDE_CONFIG_DIR` (unset if it was unset). |
| Busy: `status: "busy"` or `state: "working"` | Hold and retry on the next poll. |
| Live with work in flight: in `state.json`, `inFlight.tasks` or `inFlight.queued` above 0, or `inFlight.kinds` not empty | Hold. A stop kills that work (background Bash, agents, monitors, session crons) and drops queued input. |
| Live and idle: `status: "idle"`, `state` `done` or **`blocked`** | `--resume` would fork, and `respawn` takes no prompt. Re-read the row and the job state, then `claude stop <short id>`, then the stopped-row command. |

- **`state: "blocked"` is the main wake case, not a hold.** It means the session handed back
  waiting on the user.
- **The live-and-idle row is the common one.** The epic assumed most PRs sit with a stopped
  session. But while its bridge holds, a bot session idles 8 hours before it is stopped, so
  during a working day most wakes hit a live session.
- **The stop has costs the notifier can't see.**
  - It disconnects an attached viewer, and anything Mari has typed but not sent is lost.
    Attachment isn't visible outside the daemon (§3), so #293 has to choose a policy. It can
    accept the cost, or hold a live-and-idle wake for a while after the session's last
    `updatedAt`, betting that someone attached is active. Or it can deliver in place (the
    last bullet).
  - Checking and stopping aren't atomic. A turn can start between the re-read and the stop,
    from Mari typing or a cron firing. Re-reading right before the stop narrows that window
    but doesn't close it. The daemon's own retire has the same check-then-act shape.
- **Bound every hold.** The holds rest on Claude Code's internal job state, which can change
  between versions.
  - Treat a missing or unreadable `inFlight` as in flight, but log it every time.
  - Don't hold the same event forever. After a bound (say 30 minutes), surface it where Mari
    will see it, such as a log line the install's `check` reports, or a PR comment.
  - The same bound covers a session stopped mid-turn. One waiting on a permission prompt
    keeps `state: "working"`, and the hold would otherwise never end. Not tested: whether its
    `status` then reads `idle` or `busy`.
- **Typing into a pty-held `claude attach` is the only in-place delivery found.** Keep it
  out of child 2 unless stop-and-resume proves too disruptive. If it's used, use it only for
  `state: "done"` or `"blocked"` with `status: "idle"`, never mid-turn.

**Wake prompt: confirmed, with one addition.** A refused resume keeps its prompt and delivers
it with the next wake. So word the prompt so that getting it twice is harmless, e.g.
"re-read PR #n from GitHub", never "do X".

**Packaging and launchd (child 4).**
- **Only the user-domain route was tested.** `launchctl bootstrap user/502` works as bot
  without root when the plist sets `LimitLoadToSessionType = Background`. That's enough to
  run a job now, but not to survive a reboot without a login.
- **maguerrieri/config#47 plans LaunchDaemons instead.** Those run bot's jobs with
  `UserName bot`, need root to install, and run without a login. Whether a resume works from
  that context is untested (§2). It's the first thing #295 should test, with the keychain
  unlocked at startup as config#66 set up.
- **The job's environment.** Set a full `PATH`, since it becomes the woken session's. Don't
  set `CLAUDE_CONFIG_DIR` for the default root. If the job may be the first `claude` after a
  reboot, its environment also seeds the daemon.

**Children's scope.**
- **#293 (notifier):**
  - root-aware lookups;
  - the cwd check;
  - a timeline-based filter that also catches merges, closes and Codex's edited summary;
  - the stop-then-resume path, with its in-flight check, recheck, bounded holds and a policy
    for attached viewers;
  - a resume with no flag but `--bg`, under the install's `PATH`.
- **#294 (ticket-workflow):**
  - The subscribe call records the session id, name and `CLAUDE_CONFIG_DIR`-if-set, with no
    `PATH`.
  - FINISH unsubscribes before it removes the worktree, since a wake after that is refused.
  - Its hand-back state is `blocked`, which the notifier wakes.
- **#295 (install):**
  - test the resume from a LaunchDaemon first;
  - a full `PATH` captured at install;
  - no `CLAUDE_CONFIG_DIR` for the default root;
  - `LimitLoadToSessionType = Background` if it uses the user domain.
