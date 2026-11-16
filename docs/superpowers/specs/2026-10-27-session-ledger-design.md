# Session ledger: decisions made and what a session needs from the owner (#208)

## Problem

The owner keeps asking planners and coordinators "status?". Each answer is
rebuilt from GitHub sweeps, `claude agents`, and the session's memory of the
conversation. The two things the owner wants from that answer aren't kept
anywhere durable:

- **Decisions made**: scope changes, defers, merges authorized, design picks,
  caps raised. They're scattered across chat turns and issue comments, and lost
  when a session compacts or exits.
- **What a session needs from the owner**: a review or merge, a design decision,
  a permission prompt, an unlocked 1Password. Today these surface only when the
  owner asks, or when a child's `blocked:` ping reaches the planner's chat.

## Scope: one session's own ledger

On 2026-11-15 the owner split #208. It lands the **per-session** ledger: each
session records, resolves and lists its own decisions and needs. The
**cross-session** part (a glanceable mod and `list --all` over every local
ledger, session names from `claude agents`, and the owner or another session
resolving a session's needs) is #316. PR #272 had built and reviewed both;
the cross-session code is at its commit 5c8edb0, and the lessons it left are
under *Deferred to #316* below. A band above the prompt of this session's own
open needs came later, in #330 (*The band*, below).

## Decisions

- **Its own plugin, `ledger`.** A non-ticket session can keep a ledger too, so
  the script, the hooks, `/ledger` and the short recording rules live in
  `plugins/ledger/`. `ticket-workflow`'s charters, START and FINISH point to
  the rules where the plugin is installed, and `defaults` pulls it in.
  `ticket-workflow` doesn't list it under `dependencies`: the install that
  repo settings trigger doesn't resolve dependencies (`AGENTS.md`), so a repo
  whose settings predate `ledger` would lose `ticket-workflow` entirely.
- **Two skills, `ledger:ledger` and `ledger:record`, and no command** (#318).
  `/ledger` is `skills/ledger/`, which shows the ledger or resolves a need, and
  the recording rules are `skills/record/`, which `ticket-workflow` names.
  `/ledger` is the owner's alone (`disable-model-invocation: true`): its
  `resolve` form is the owner marking a need answered, and a session reads and
  resolves its ledger by the rules (*When to read*, *Resolve a need*) instead.
  The rules are the model's alone (`user-invocable: false`). The plugin first
  shipped `/ledger` as `commands/ledger.md` beside a skill also named
  `ledger`. A plugin's commands and skills share one namespace, so the
  two registered as one `ledger:ledger` entry: the listing showed the
  command's description, and invoking it loaded the skill's body. Renaming the
  skill alone isn't enough, because a bare `/ledger` resolves only to a
  skill: with `/ledger` left a command, an interactive session answers
  `Unknown command: /ledger` and only `/ledger:ledger` reaches it (verified on
  Claude Code 2.1.325). `AGENTS.md` has the rule.
- **The band** (#330). The plugin's hooks module (`hooks/register.tsx`, a mod)
  draws a row above the prompt while this session has an open need: the count
  and the newest need, with Show and Hide. Show, or `/ledger-band`, expands it
  in place into each open need, its first line, Why line, ref and age and a
  Resolve button; Less, or the command again, folds it. Hide quiets it until
  a need it didn't show opens: the mock came back when the set of open needs
  changed at all, a resolve included, which brought back needs the owner had
  just dismissed. A band whose last need goes folds, so the next need arrives
  as the one-row summary. It is option 4 (`inline`) of #319's mock, which
  the owner picked on 2026-11-16 for this session alone, over the mock-up's
  recommendation of option 3 (a band that opens a pane of every session).
  So it shows no decisions or resolved needs, as the mock's option 4 doesn't.
  It reads this session's ledger file and no other, through one function,
  `readLedgers`, that #316 can widen to every session without redrawing the
  band; it reads at the session's start, every 15 seconds, and as each turn
  of the main loop ends (where a session records its needs), and keeps what it
  last showed when a read fails. Only a stat that fails `ENOENT` reads as no
  ledger yet: `$.fs.exists` says false for a file in a directory it can't
  search, which the script refuses (checked on 2.1.325). Resolve is the
  owner's, as `/ledger resolve` is: it runs `ledger.sh resolve <id>` from the
  plugin's folder (the session's own may be a removed worktree, where no child
  starts) with `CLAUDE_CODE_SESSION_ID` set to this session and
  `CLAUDE_SESSION_LEDGER_DIR` to the directory the band read, made absolute,
  so the script stays the one writer and writes the ledger the band showed,
  and it refuses a need the
  band showed before a `/clear` (an earlier session's). It has no hotkey, since
  a digit typed into an empty prompt presses a band button, and a need id the
  script would refuse gets no button. The toggle is a command the module
  registers, which a bare `/ledger-band` reaches; a mod can't bind a key, so
  the README gives the `keybindings.json` line for one. Its tests run under
  `claude plugin test plugins/ledger`, and CI runs them and validate on the
  build the band was checked on, pinned (2.1.325).
- **One JSONL file per session**, keyed like the role marker:
  `~/.claude/session-ledger/<session id>.jsonl` (`CLAUDE_SESSION_LEDGER_DIR`
  overrides it for tests). The session id is `CLAUDE_CODE_SESSION_ID`, else the
  `CLAUDE_SESSION_ID` the plugin's SessionStart hook (and ticket-workflow's)
  exports on older CLIs. Each line is one entry:
  `{kind: "decision"|"need", id, why, text, ref?, at, cwd, resolved_at?}`.
  `id` is `d<n>` or `n<n>`, numbered per kind within the file from the highest
  well-formed id (at most nine digits, so a hand-edited `n1.5` can't break the
  arithmetic, and numbering stops at the last one rather than repeat it).
  Which lines count as entries is one jq definition, `scripts/is-entry.jq`,
  that the script's reads, its resolves and the hook's reaping all load.
  `cwd` is where
  the session wrote from, which nothing here reads yet; it's kept so #316 can
  name a session that `claude agents` doesn't list (an interactive one).
- **Refs** go through one function, `normalize_ref`, on write and on
  resolve, so the two always agree. A ref is given in full: `<owner>/<repo>#<n>`,
  a GitHub issue or PR URL (stored as `<owner>/<repo>#<n>`, since START and
  FINISH read the repo from a PR's URL), or another tracker's key. A bare
  `#<n>` is a shorthand for the checkout's own repo, qualified from origin;
  outside such a checkout it stays bare, and in a fork it names the fork, so
  START's hand-back, the implementer's `blocked:` need, the coordinator's
  stack need and FINISH all spell out the full ref. The owner and repo are
  lowercased, since GitHub ignores their case and origin's spelling can differ
  from a PR URL's. A `#` must be followed by a number (a lone `#` named
  nothing and could never be resolved), and a ref has at most one.
- **Locking.** A write holds the ledger directory's one lock from its read to
  its rename, since a session's parallel tool calls can write its ledger at
  once and the reaping (below) deletes in the same directory. The lock is
  `flock(2)` on `.lock` in the ledger directory, taken by perl on a descriptor
  the script's shell keeps open, so the kernel drops it when the holder dies.
  A lock file that can be deleted and remade (`mkdir`, a symlink naming the
  holder) needs stale-lock reclaiming, and a reclaiming waiter can remove a
  successor's live lock: Codex reproduced lost entries that way on PR #272.
  For the same reason the lock file is never deleted, so the reaping skips it.
  Copilot found that reaping the per-ledger lock files an earlier version kept
  could unlink one a writer had just opened. One lock for the whole directory
  leaves nothing to reap, and writes are few and brief enough that sharing it
  costs nothing. Every write goes through a temp file and a rename, so a
  reader never sees half a line.
- **Every entry opens with a Why line** (the owner's request on PR #272,
  2026-11-14): `Why: <history and goal>`, one short line on why the work the
  entry is about exists, since a small in-the-weeds issue is easy to forget
  the reason for when its need is read days later. It's the first line of the
  text on stdin, stored as `why` (at most 200 bytes), and the script refuses
  an entry without one, so writers can't skip it. `list` prints it above the
  entry's text. Entries written before it have no `why` and still list. The
  Why line and the text refuse control characters (NUL included, which a
  shell variable would otherwise drop) and invisible formatting characters
  (bidi overrides and isolates, zero-width characters, line separators), so
  text pasted from an issue can't make `list` read differently from what was
  recorded.
- **Writes go through `scripts/ledger.sh`**: `add-decision` and `add-need` (a
  Why line, then the text, on stdin through a quoted heredoc, `--ref`
  optional), `resolve <id>`, `resolve --ref <ref>` (this session's open needs
  under a ref, which FINISH runs when a PR lands), and `list`. Text on stdin
  keeps quotes and `$` literal, the same way `role-marker.sh notify` takes a
  session name.
- **A need lives only in the ledger of the session that needs the owner.** A
  spawner doesn't copy a child's `blocked:` into its own; it relays it as
  before. (A version that copied it up the tree showed open needs that shared
  a ref as one row, which also merged two different needs under one PR, hid
  the second, and resolved both on one Resolve. #316 reads each session's
  ledger instead.)
- **Subagents can't write their parent's ledger.** A subagent's Bash runs with
  the same environment as its parent (checked on 2.1.312: the variable names
  match), so the script can't tell it apart. The PreToolUse hook can: a
  subagent's call carries an `agent_id`. It denies a subagent's Bash that runs
  `ledger.sh` with a writing subcommand. Reads (`list`) pass. The rule is
  ticket-workflow's marker-write rule with the script and its read swapped;
  the plugins install separately, so it's a copy, and a test fails if the two
  drift apart.
- **"status?" starts from the ledger.** The planner and coordinator charters
  start from `ledger.sh list` (their own decisions and needs), then sweep the
  children as before, until #316 brings the children's ledgers into one view.
- **Garbage collection**: the SessionStart hook deletes ledger files untouched
  for 90 days. That's longer than the 30 ticket-workflow gives role markers,
  because a ledger holds what the owner decided and what a session still
  needs from them, and a session may be resumed after a month away. One age
  for every ledger keeps the reaping to a `find`: an earlier version kept
  ledgers with an open need longer by parsing each one under the lock. The
  reaping runs under the directory's lock: unlocked, it could check a ledger's
  age just before a write renamed an updated one into place, and delete the
  new entry with the old ones. When the lock can't be had within two seconds,
  it skips its turn. The hook's refresh of its own session's ledger happens
  under the same lock, so another session's reaping sees the ledger fresh or
  not at all; without the lock the refresh still runs.
- **Local sessions only.** The charters, START and FINISH record only in a
  local session: a cloud session can have the plugin installed (this repo's
  SessionStart hook installs it there), but its ledger dies with its
  container and nothing the owner reads reaches it.
- **Refs from origin.** A bare `#<n>` is qualified only from an origin shaped
  `host:owner/repo` or `scheme://host/owner/repo`; a local path or nested
  groups would yield a wrong pair, so the ref then stays bare. A URL ref needs
  its scheme, and one without is refused rather than stored unmatched.

## Deferred to #316

What PR #272 learned about the cross-session part, so #316 doesn't relearn it:

- `list --all` and the mod read every local ledger; with them, a spawner
  never needs a copy of a child's need.
- `claude agents --json --all` rows carry `sessionId`, `name` and `id` (the
  attach handle). It can hang: give it five seconds, then TERM, then KILL a
  second later, since one that ignores TERM held the wait forever. Ask it only
  while another session has an open need, since names label only those.
- The mod: mark a view shown only once its write succeeds; drop a refresh a
  later one overtook; keep the last-read view on a failed listing and a
  ledger's last-read entries on a failed read, but treat a missing directory
  as empty; pin CI to a CLI build, since the function-hook API is early access.
- `list --all` should skip and report one unreadable ledger rather than fail;
  a sweeping `resolve --ref` should report a ledger it left unresolved while
  still resolving the rest.
- The panel's shape is #319's: it mocked four options in `mocks/ledger-panel/`
  for the owner to pick from, and `2026-11-15-ledger-panel-options.md` has
  them, what the mod API can do for toggling one (on 2.1.325), and a
  recommendation. The owner picked option 4, built for this session alone in
  #330 (*The band*, above). Widening it means widening `readLedgers` to every
  ledger file, labeling each need with its session (the mock's `labelOf`), and
  deciding whether Resolve reaches another session's need, which the band now
  refuses.

## Out of scope

Cloud sessions (they can't see local ledgers, and SendMessage doesn't reach
them), and anything synced off-machine.
