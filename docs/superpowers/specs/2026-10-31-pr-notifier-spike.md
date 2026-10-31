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
| 1 | Idle stop | Yes, but **8 hours, not 1, for every `bot` session**: bot runs with `remoteControlAtStartup: true`, and a Remote Control-bridged session gets the longer limit. An unbridged one stops after 1 hour. Attached and pinned sessions, and ones with background work in flight, are skipped. **Under memory pressure** the limit drops to 60 seconds, bridged or not, and pinned sessions go as a last resort. (read; tested: the 1-hour stop, and a bridged session still live after 5 hours) |
| 2 | Resume from launchd | Works from a real launchd job in `user/502` and from `env -i`, with no TTY and no direnv; keeps the id, name and row. Three traps: **any flag next to `--resume` starts a copy**, **the job's `PATH` becomes the woken session's tool `PATH`**, and **setting `CLAUDE_CONFIG_DIR=~/.claude` is not the same as leaving it unset** (the resume is refused). Locked keychain: untested. (tested) |
| 3 | Waking a live, idle session | `--resume` on a live session **forks a copy**; `claude respawn` restarts it but **takes no prompt**. What works: `claude stop` then `--resume` (context kept; an attached viewer is disconnected), or typing into a pty-held `claude attach` (in place, but fragile). (tested) |
| 4 | Which notifications arrive | Copilot's and Codex's reviews appear within about 20 seconds, as `reason: author`. The bot's own posts don't appear. `X-Poll-Interval` is 60, and a conditional request's 304 costs no rate limit. **The owner-side events (Mari's comments, reviews, a merge) are still pending**, waiting on Mari's actions on #296. (tested; owner rows pending) |
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
with `s` = `fr=28800000`). Under memory pressure (macOS memory-status pressure, or little
free memory) both thresholds drop to 60 seconds (`Qe=60000`). If that sweep retires nothing,
a second pass retires sessions whose only work in flight is monitors, once they've been idle
8 hours (`shedMonitoringOnly`, `bt=28800000`). If pressure persists after that, pinned
sessions go too ("retiring pinned settled workers as a last resort"). A retire logs
`bg retire <id>: <cause>, idle <n>m` and `bg settled <id> (done)`.

**bot's sessions are all bridged.** `~/.claude/settings.json` sets
`remoteControlAtStartup: true`, and every job under `~/.claude/jobs/` has a
`bridgeSessionId`. So a bot session waits **8 hours** idle, not about one, before it is
stopped. The daemon log agrees: `2ad34855` sat idle for 409 minutes (08:42–15:31) with no
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

**Trap 1: any flag next to `--resume` starts a copy.** With `--model haiku` added:

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

**Untested:**

- **A locked keychain.** Locking bot's keychain would cut off every running bot session,
  and I can't unlock it again (no password), so I didn't. What I could see: the daemon
  refreshes the OAuth login itself (`auth: proactive refresh` in its log), and a resume
  hands off to the running daemon, so a resume may not touch the keychain at all while the
  daemon runs. What fails after a reboot with the keychain locked is maguerrieri/config#66's
  question. Test it there: lock, run the job, read its stderr.
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
- **A 304 costs no rate limit.** At 22:23, with bot quiet, 20 conditional requests in a row
  all returned `304 Not Modified`. In their own headers, 19 reported `X-RateLimit-Used: 55`
  and one reported 54. Twenty requests moved the count by one, which the poller's or
  another session's request accounts for: every bot session shares the token's 5,000/hour. An earlier
  run during busy minutes saw ten 304s move `used` by one, which fits the same reading.
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
or on `@codex review`; on a clean review it edits one summary comment
(`<!-- codex-pull-request-review-summary -->`, with a `codex-review-state` JSON line) and adds
a 👍. Copilot ran out of quota for bot between 17:10 and 17:13: every Copilot review after
that (claude-config#147 at 17:16:19, toolbox#860 at 17:13:19, toolbox#861 at 17:16:48, #296
at 17:17:15) reads *Copilot was unable to review this pull request because the user who
requested the review has insufficient remaining quota.*

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

What the answers do to the epic's sketch:

**Subscribe: record more, and record it exactly.**
- Keep the full session id, which `--resume` takes, and the name. Its first 8 characters are the short id
  that names the job directory (`e71c5d32` for `e71c5d32-20dd-…`).
- The launch dir isn't needed: the resume works from any cwd, and the session keeps its own.
  Record it for diagnostics at most, and never `cd` into it to wake, because a removed
  worktree would break the wake.
- Record `CLAUDE_CONFIG_DIR` **only if it is set**, and wake with it unset when it was
  unset. Setting `~/.claude` explicitly breaks the default root (Trap 3).
- Record the session's `PATH` at subscribe time and wake with it: the waker's `PATH` becomes
  the woken session's tool `PATH` for the rest of its life (Trap 2).

**Poll: confirmed.**
- `If-Modified-Since` with a free 304 works, and `X-Poll-Interval` is 60.
- Expect 200s while bot is busy and 304s when it's quiet. Either way it's cheap.
- Use a classic token with `repo` or `notifications` scope, as bot's `gh` login has.
  GitHub's REST docs say fine-grained and GitHub App tokens can't read this endpoint (not
  tested).

**Filter: fetch, don't trust the notification.**
- A thread change carries no author and no event type, and `updated_at` moves for edits and
  reactions too.
- So for a subscribed PR, list its comments, review comments and reviews newer than the last
  wake, and apply the owner and review-bot checks to their authors. The bot's own posts
  never show up in its feed, but keep the check anyway.
- Codex's "no findings" is a 👍 plus an edited comment, not a new comment. Decide whether
  that should wake the session: it's the review a session waits on.
- Still open until Mari's events land: whether owner reviews and line comments each move the
  thread, and with which `reason`.

**Deliver: the state table changes.**

Look each session up in its own root:
- run `claude agents --json --all` with the recorded `CLAUDE_CONFIG_DIR`, unset if it was
  unset;
- read its job state at `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/jobs/<short id>/state.json`.

Then:

| State | Action |
|---|---|
| Stopped: `pid: null` | `claude --bg --resume <session id> "<wake prompt>"` with **no other flags**, from any cwd, with the recorded `PATH` and `CLAUDE_CONFIG_DIR` (unset if it was unset). |
| Live and idle: `status: "idle"`, `state` `done` or **`blocked`**, nothing in flight | `--resume` would fork, and `respawn` takes no prompt. Re-read the row and the job state, then `claude stop <short id>`, then the stopped-row command. |
| Live with work in flight: in `state.json`, `inFlight.tasks` or `inFlight.queued` above 0, or `inFlight.kinds` not empty | Hold. A stop kills that work (background Bash, agents, monitors, session crons) and drops queued input. |
| Busy: `status: "busy"` or `state: "working"` | Hold and retry on the next poll. |

- **`state: "blocked"` is the main wake case, not a hold.** It means the session handed back
  waiting on the user.
- **The live-and-idle row is the common one.** The epic assumed most PRs sit with a stopped
  session. With bridged sessions idling 8 hours, that holds only overnight.
- **The stop has costs the notifier can't see.**
  - It disconnects an attached viewer, and anything Mari has typed but not sent is lost.
    Attachment isn't visible outside the daemon (§3), so #293 has to choose a policy. It can
    accept the cost, or hold a live-and-idle wake for a while after the session's last
    `updatedAt`, betting that someone attached is active. Or it can deliver in place (the
    pty bullet below).
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
- `launchctl bootstrap user/502` works as bot without root, as long as the plist sets
  `LimitLoadToSessionType = Background`.
- Untested: whether it survives a reboot from `~/Library/LaunchAgents` without a login.
  That's maguerrieri/config#47's question.
- The job must set a full `PATH`. It must not set `CLAUDE_CONFIG_DIR` for the default root.
- If it may be the first `claude` after a reboot, its environment seeds the daemon.

**Children's scope.**
- **#293 (notifier):** gains these:
  - the `PATH` and config-dir recording;
  - root-aware lookups;
  - the fetch-and-filter step;
  - the stop-then-resume path, with its in-flight check, recheck, bounded holds and a policy
    for attached viewers;
  - the flag-free resume.
- **#294 (ticket-workflow):** its subscribe call must pass the session's `PATH` and
  `CLAUDE_CONFIG_DIR`-if-set. Its hand-back state is `blocked`, which the notifier wakes.
- **#295 (install):** gains `LimitLoadToSessionType = Background` and the no-config-dir rule
  for the default root.
