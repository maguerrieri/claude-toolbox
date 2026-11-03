# Installing pr-notifier for the `bot` user

The notifier (#293, [README](README.md)) is a plain program that has to keep running,
across reboots, as the macOS user that owns the sessions it wakes: `bot`, on Mari's Macs.
A plugin can't keep a daemon alive, and its cache directory moves with every release, so
this install puts it under launchd, behind paths that don't move (#295). Mari runs the
checklist below once per Mac.

## What gets installed

| What | Where | Written by |
|---|---|---|
| The stable CLI path | `~/.local/bin/pr-notifier` | `scripts/install.sh`, from `scripts/pr-notifier-shim.sh` |
| The job script | `~/.local/libexec/pr-notifier-job` | `install.sh`, from `scripts/pr-notifier-job.sh` |
| `wake_path` | `~/.local/state/pr-notifier/config.json` | `install.sh`, captured from bot's login shell |
| The `jq` the job reads `config.json` with | `~/.local/state/pr-notifier/jq-path` | `install.sh`: the one `wake_path` finds |
| The launchd job | `/Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist` | Mari, as root (step 2) |
| Logs | `~/.local/state/pr-notifier/`: `notifier.log` (the CLI), `job.log` and `job.last` (the job) | the notifier, as bot |

`install.sh` runs as bot and changes only what differs, so running it again changes
nothing. It never runs as root: the one root step is a paste (step 2).

**Each minute, the job:**

1. rotates `job.log` and `notifier.log` once either passes 1 MiB, keeping one old copy
   as `<log>.1`, so each takes at most about 2 MiB;
2. unlocks bot's **default keychain** with its empty password, and skips the run if that
   fails, since `claude` finds no login in a locked keychain. It asks `security
   default-keychain` which one that is rather than naming a file: a keychain named
   `login.keychain-db` can't be unlocked by password once it's locked
   (maguerrieri/claude-config#144), and on the Mac Studio bot's is `bot.keychain-db`;
3. sets `PATH` to `wake_path`, the `PATH` a fresh bot login shell has, captured by the
   install. Every `claude` the notifier runs gets it. A session it resumes keeps its
   waker's `PATH` as its tool `PATH` for the rest of its process (the #292 spike's Trap 2),
   so a resume passes the session's own `PATH`, recorded when it subscribed, with
   `wake_path`'s other entries behind it: a session never loses a tool it had, and never
   lacks one the install found. A relay restarts nothing, so the session keeps its own
   environment (the [README](README.md)'s *The session's PATH*);
4. runs `~/.local/bin/pr-notifier check` from `/`, with no `CLAUDE_CONFIG_DIR`: each
   subscription records its own, and setting `~/.claude` explicitly breaks the default
   root (Trap 3). On start after downtime, `check` catches up from its cursor.

`job.last` holds the last run's outcome (`ran check`, `check failed: exit <n>`, or
`skipped: <why>`), which `install.sh status` reads.

## Why a LaunchDaemon

From the #292 spike ([findings](../../docs/superpowers/specs/2026-10-31-pr-notifier-spike.md),
§2 and *Packaging and launchd*):

- bot never logs in to the desktop, so it has no `gui/502` domain, and a LaunchAgent
  there never loads.
- The user domain, `user/502`, works without root: the spike resumed a session from a job
  bootstrapped there, once its plist set `LimitLoadToSessionType` to `Background`. But
  that domain exists while bot has processes, and isn't known to come back after a reboot
  with nobody running as bot.
- A **LaunchDaemon** with `UserName` bot runs in the system domain at boot, with nobody
  logged in, which is maguerrieri/config#47's route for bot's jobs. Installing one needs
  root, so the spike couldn't test a resume from it. Step 4 is that test.

So the default is the LaunchDaemon, with the user-domain agent as the fallback if step 4
fails (*Fallback*, below).

**The plist is a paste, from this file as reviewed on GitHub.** It's root's file, and its
content decides which user the job runs as, so it never comes from a file bot can edit (a
checkout of bot's, or the plugin cache). Nothing in it varies by install, and launchd opens
no file for it: it has no `StandardOutPath` or `StandardErrorPath`, and the job script
redirects its own output as bot. So root never writes into a directory bot controls
(config#47's reason for keeping its logs out of bot's home). `AbandonProcessGroup` keeps a
`claude` daemon that the job's `claude` call starts (the first one after a reboot) alive
when the job exits.

## Checklist

Run every step from a `sudo -iu bot` shell, except step 2 (root, in your own shell) and
step 5's reboot.

**In each new bot shell**, first define `pni`, which runs `install.sh` from bot's
default config root, where step 1 installs the plugin. That copy hands over to the newest
copy in any of bot's config roots (`~/.claude`, `~/.claude-*`), the one the shim runs the
CLI from:

```zsh
pni() {
  local v
  v=$(ls ~/.claude/plugins/cache/maguerrieri-toolbox/pr-notifier 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
  [ -n "$v" ] || { echo "pr-notifier isn't installed in ~/.claude; see step 1" >&2; return 1; }
  bash ~/.claude/plugins/cache/maguerrieri-toolbox/pr-notifier/$v/scripts/install.sh "$@"
}
```

### 1. bot's side

```zsh
claude plugin marketplace update maguerrieri-toolbox
claude plugin install pr-notifier@maguerrieri-toolbox
pni
```

It prints a line per piece (`wrote …`, `set wake_path …`), then `next: the LaunchDaemon
isn't installed`. Check the `wake_path` it printed: it's what every woken session's tools
will see. If it's wrong, run `pni --path '<the PATH>'`. It stops without writing anything
if that `PATH` doesn't find `claude`, `gh`, `jq`, `bash` and the basic system tools
(`sed`, `awk`, `date`, `mv`, `mkdir`).

### 2. The LaunchDaemon (your own shell, as root)

Copy this block from GitHub, not from a file on the Mac:

```zsh
sudo tee /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist >/dev/null <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>works.sprue.bot.pr-notifier</string>
  <key>UserName</key>
  <string>bot</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>/Users/bot/.local/libexec/pr-notifier-job</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>/Users/bot</string>
    <key>USER</key>
    <string>bot</string>
    <key>LOGNAME</key>
    <string>bot</string>
    <key>SHELL</key>
    <string>/bin/zsh</string>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
    <key>PATH</key>
    <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>/</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>AbandonProcessGroup</key>
  <true/>
</dict>
</plist>
PLIST_EOF
sudo chown root:wheel /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist
sudo chmod 644 /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist
sudo launchctl bootout system/works.sprue.bot.pr-notifier 2>/dev/null
for i in {1..30}; do sudo launchctl print system/works.sprue.bot.pr-notifier >/dev/null 2>&1 || break; sleep 1; done
sudo launchctl bootstrap system /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist
```

The `bootout` and the wait only matter when replacing a loaded job (a bootstrap right
after a bootout fails with `Bootstrap failed: 5`); the first time, they do nothing. The
job runs at once, then every 60 seconds.

### 3. Check that it runs

```zsh
pni status
```

Expect `status: ok`, with `system/works.sprue.bot.pr-notifier is loaded: state=…
runs=… last-exit=0` and `the job's last run: … ran check`. Any `FAIL` line says what to
fix; `job.last` also records a `check` that failed (`check failed: exit …`). With nothing subscribed yet, `notifier.log` gains a `check skipped=no-subscriptions`
line a minute.

### 4. Test a wake from the LaunchDaemon

This is what the spike couldn't test: a relay and a resume, each run by the LaunchDaemon.
The relay matters more. It's a `claude` client of its own, so it needs bot's Claude login
from the job's context, while a resume hands off to the running daemon. A cheap test
session subscribes to a bot PR, and you comment on the PR twice: once while the session is
live, and once after it has stopped. Pick any open PR that `sprue-works-bot` opened, and set
`pr` to it:

```zsh
pr='maguerrieri/claude-toolbox#296'
cd ~/Developer/claude-toolbox
claude --bg -n 'pr-notifier install test' --model haiku 'Reply with one word: ready.'
sleep 20
sid=$(claude agents --json --all | jq -r '[.[] | select(.name == "pr-notifier install test")] | last | .sessionId')
~/.local/bin/pr-notifier subscribe "$pr" --session "$sid" --name 'pr-notifier install test'
claude agents --json --all | jq --arg s "$sid" '.[] | select(.sessionId == $s) | {state, status, pid}'
```

**The relay.** The session is live and idle: `"status": "idle"`, with a `pid`. Comment on
the PR from your own GitHub account (anything, such as "notifier test 1"). Within about two
minutes, or six if the notification doesn't move (the notifier also reads every subscribed
PR every five minutes):

```zsh
grep "session=${sid:0:8}" ~/.local/state/pr-notifier/notifier.log | tail -n 3
claude agents --json --all | jq --arg s "$sid" '.[] | select(.sessionId == $s) | {state, status, pid}'
```

Expect a `wake session=… how=relay … msg=…` line, and the same `pid` as before: the session
took the wake in place. `claude attach ${sid:0:8}` shows it as a message from `pr-notifier`
with the wake prompt (`pr-notifier wake v1: …`) inside, and the session's answer. A
`relay-failed … reason=…` line means the relay didn't land. Record its reason in step 6.
The notifier then falls back to stopping and resuming the session, once it has been quiet
for ten minutes.

**The resume.** Stop the session, then comment on the PR again ("notifier test 2"):

```zsh
claude stop ${sid:0:8}
```

Expect a `wake session=… how=stopped` line within the same few minutes, and a `pid` on the
session's row again. Then clean up:

```zsh
~/.local/bin/pr-notifier unsubscribe "$pr" --session "$sid"
claude stop ${sid:0:8}
```

If no wake comes, `notifier.log` says why (`hold`, `relay-failed … reason=…`, or
`wake-failed … detail=…`), and `~/.local/state/pr-notifier/job.log` has the job's own
errors. If the resume fails from the LaunchDaemon, use the fallback below and note it in
step 6. If only the relay fails, wakes still arrive by stop-then-resume. Note its reason in
step 6, and if it keeps failing, turn it off by adding `"relay": false` to
`~/.local/state/pr-notifier/config.json` (the install keeps keys it doesn't set).

### 5. Reboot

Reboot the Mac and log in as usual, but **don't open a bot shell** first: bot's login
shell unlocks its keychain too, and would hide whether the job's own unlock works. From
your own shell:

```zsh
sudo launchctl print system/works.sprue.bot.pr-notifier | grep -E 'state =|runs =|last exit code ='
sudo cat /Users/bot/.local/state/pr-notifier/job.last
```

Expect `runs` above 0 and a `job.last` written after the reboot that reads `ran check`.
`skipped: couldn't unlock …` means a daemon can't unlock bot's keychain with nobody
logged in as bot (config#47's open question). Record it in step 6.

### 6. Record the results

Comment on the maguerrieri/claude-config issue linked from #295 with what steps 3 to 5
printed: the `status` summary, the relay's and the resume's `wake` lines and how long
each took, the reboot lines,
which route you ended up on, and anything that didn't work. That issue records them in
claude-config's `AGENTS.md`, *The `bot` macOS user*.

## After a plugin update

The CLI needs nothing: the shim runs the newest installed copy. `pni status` (step 3)
says when the job script or the shim differs from the newest version's; run `pni` again.
With no `--domain`, `pni` keeps whichever job is installed, so this is the same on the
fallback. If `status` says the LaunchDaemon's plist differs, run step 2 again with this
file's new block.

## Uninstall

The LaunchDaemon first, in your own shell, so launchd isn't left running a job that's
gone:

```zsh
sudo launchctl bootout system/works.sprue.bot.pr-notifier
sudo rm /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist
```

Then from a bot shell:

```zsh
pni uninstall
```

It refuses while the LaunchDaemon's plist is still there. It removes the job script and
the shim (sessions then skip subscribing, as the skill says), and keeps
`~/.local/state/pr-notifier` (subscriptions, logs, `config.json`); delete that by hand to
start over.

## Fallback: the user-domain agent

If step 4 shows a LaunchDaemon can't resume sessions, uninstall the LaunchDaemon (its root
lines above), then from a bot shell:

```zsh
pni --domain user
```

It needs no root: it writes `~/Library/LaunchAgents/works.sprue.bot.pr-notifier.plist`
(the same job, with `LimitLoadToSessionType` `Background` in place of `UserName`) and
bootstraps it into `user/<uid>`, the route the spike tested. It isn't known to come back
after a reboot, so check with `pni status` after one, and run `pni` again from a bot
shell if it didn't. From then on a plain `pni` keeps the agent. To go back, install the
LaunchDaemon (step 2), then run `pni`: once the LaunchDaemon is loaded, it removes the
agent, and until then it keeps the agent running.
