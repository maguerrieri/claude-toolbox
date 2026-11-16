# Ledger panel: options for the owner to pick from (#319)

The `ledger` plugin (#208, PR #272) keeps each session's decisions and what it
needs from the owner, but `/ledger` is the only way to see them. #316 will
build a glanceable view across sessions. This doc offers four ways that view
could work, each a working mock, so the owner can pick one before #316 builds
it. It also says what the mod API can and can't do for toggling a panel.

**The owner's pick (2026-11-16): option 4, `inline`, for this session only for
now.** #330 built it in the `ledger` plugin as `/ledger-band` (the session-ledger
design's *The band* has what it kept), and the view across sessions stays
#316. The recommendation below, option 3, wasn't taken.

Everything here was checked on Claude Code **2.1.325**, in a 160×50 terminal
in the fullscreen layout, by driving `claude --plugin-dir mocks/ledger-panel`
in a pseudo-terminal and reading its screen. The captures below are that
screen's text, trimmed.

## Loading the mock

The mock is one scratch plugin, `mocks/ledger-panel/`, outside `plugins/` and
the marketplace. It never writes a ledger: Resolve marks a need resolved in
the mock's own state and says what the real panel would run.

```sh
claude --plugin-dir mocks/ledger-panel
```

Two options pick what it shows. Change them in `/config` (*Panel option*,
*Ledger source*), which reloads the mock, or start with a settings file:

```sh
printf '%s\n' '{"pluginConfigs":{"ledger-panel-mock":{"options":{"variant":"band","source":"fixtures"}}}}' > /tmp/ledger-mock.json
claude --plugin-dir mocks/ledger-panel --settings /tmp/ledger-mock.json
```

- `variant`: `pane` (the default), `status`, `band` or `inline`, the four
  options below.
- `source`: `fixtures` (the default) reads `mocks/ledger-panel/fixtures/`;
  `live` reads your own ledgers (`~/.claude/session-ledger`, or
  `CLAUDE_SESSION_LEDGER_DIR`) and names other sessions from
  `claude agents --json --all`.

The fixtures are six sessions' ledgers. One line is real: `n1` of session
`064d2730` (#208's), copied verbatim from the one ledger on the machine the
mock was built on. In fixtures mode that session plays "this session". The
other sessions, their names and their PRs are real (from `claude agents` and
`gh pr list` on 2026-11-15), but their entries were written for the mock from
each issue's motivation, since those sessions predate the ledger.

Every option toggles with `/ledger-pane`. For a key, add a chord to
`~/.claude/keybindings.json` (any free chord works; `ctrl+x l` is free by
default):

```json
{
  "bindings": [
    { "context": "Chat", "bindings": { "ctrl+x l": "command:ledger-pane" } }
  ]
}
```

`claude plugin test mocks/ledger-panel` runs the mock's tests (each option's
toggle and drawing on the terminal and desktop trees).

## What the mod API can do for toggling

| Question | Answer on 2.1.325 | How it was checked |
| --- | --- | --- |
| Open a pane from a command | Yes: `$.command.register` and `$.ui.open` | Typed `/ledger-pane`: the pane docked beside the transcript |
| Close its own pane from code | Yes: `$.ui.close({ id })`; `$.ui.panes()` says whether it is open, so one command toggles | `/ledger-pane` twice: open, then closed |
| The person dismisses it | The pane's `✕` mark; `ctrl+x x` while the pane has the keyboard (`pane:close`, *Pane* context); Esc, when the mod opened it with `closeOnEscape`, both while the pane has the keyboard and at an idle, empty prompt. A mod's `ui.close` hook may refuse any of these | `ctrl+x x` from the prompt did nothing; after `ctrl+x tab` it closed the pane. Esc closed it in both places |
| Give the pane the keyboard | `ctrl+x tab`; then a Button's one-key `hotkey` presses it | `r` toggled *Show resolved*, and `1` pressed the first Resolve (the mock has since dropped digit hotkeys, below) |
| Bind a keyboard shortcut | **A mod can't register one.** The person can bind a chord to the mod's command in `keybindings.json`: `"ctrl+x l": "command:ledger-pane"`. That toggles, since the command does | Bound it as above: `ctrl+x l` opened the pane, and again closed it (expanded and folded the band for `inline`) |
| Borrow an engine chord | A Button's `action` prop takes an engine keybinding action's chord, but only one with no engine handler mounted, and plugins can't define new actions | Read in the types; not tried, since no free engine action fits |
| Hide or collapse a band | The person collapses the whole band with `ctrl+x ctrl+a` or its `[-]`; a mod can stop drawing its row (the mock's Hide) | Hide verified in tests; `[-]` seen on screen |
| Open without being asked | Waits undrawn below 144 columns (110 for an id the person has opened before) | From the types; every option here opens only on request |

Two more limits shape the options:

- A bare digit typed into an empty prompt presses a band Button with that
  hotkey (that's how surveys answer), so band buttons that act, like Resolve,
  must have no digit hotkey. A pane's hotkeys fire only while it has the
  keyboard, but digits by position shift after each Resolve, so pressing `1`
  twice would resolve two needs: the mock gives Resolve no digit hotkey
  anywhere.
- A status line (`$.ui.status`) is drawn after `⚠ <plugin name>:` and cut at
  the terminal's width, and it can't be pressed.

## The options

### 1. `pane`: a pane on demand, this session

Nothing shows until the person asks. `/ledger-pane` (or the chord) opens a
pane of this session's open needs, a *Show resolved* toggle and the session's
latest decisions; the same command, Esc, `✕` or *Close* closes it.

```text
│                                                                     ✕
│This session [ Show resolved ] [ Close ]
│Open needs (1)
│n1 · maguerrieri/claude-toolbox#272 · 24m
│Why: #208: "status?" answers were rebuilt from scratch each time, so
│sessions now keep a ledger of decisions and needs
│Do PR #272's manual check now that it's merged: run /ledger and confirm
│this need lists under its Why line, then run /ledger resolve n1 and
│confirm it shows as resolved.
│[ Resolve ]
│
│Decisions in this session (2)
│d2 · maguerrieri/claude-toolbox#316 · 6h
│Why: #208: "status?" answers were rebuilt from scratch each time, so
│sessions now keep a ledger of decisions and needs
│Split the cross-session view out: PR #272 lands the per-session ledger,
│and #316 builds the view across sessions
│
│d1 · maguerrieri/claude-toolbox#208 · 28h
│...
```

- **Shows**: this session only, needs and decisions, resolved needs on
  request.
- **Does**: Resolve per need.
- **Loudness**: silent until asked.
- **Costs**: the least to build; needs nothing from #316's reader. But it
  answers "what does *this* session need?", which the hand-back report
  already says, and never tells the owner that another session is waiting.

### 2. `status`: the same pane, plus a status line

Option 1, plus one line under the prompt while this session has an open need:

```text
❯ Try "how do I log an error?"
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  ⚠ ledger-panel-mock: 1 open need (/ledger-pane), newest: Do PR #272's manual check now that it's merged: run /ledger and confirm this need lists under its …
```

- **Shows and does**: as option 1.
- **Loudness**: one line while a need is open; it can't be hidden or pressed,
  and the engine's `⚠` reads as a warning.
- **Costs**: about as cheap as option 1, with the same blind spot for other
  sessions. Moving it to every session's needs would make it option 3 with a
  worse row.

### 3. `band`: a band row that opens a pane of every session

A one-row band above the prompt while any local session has an open need:
the count, the newest need, *Open* and *Hide*. Hide keeps it quiet until the
set of open needs changes. *Open* (or `/ledger-pane`, or the chord) shows the
pane of every session's open needs, each under its session's name and Why
line, and this session's decisions. The pane is a sidebar, so Esc doesn't
close it; the toggle, `✕` or `ctrl+x x` does. This is the design PR #272 built
before the cross-session part was split out.

```text
5 open needs this session: Do PR #272's manual check now that it's merged: run /ledger and confirm this need lists under its Why line, t… [ Open ] [ Hide ] [-]
```

With the pane open, the band narrows to the transcript's column:

```text
│Every session [ Show resolved ] [ Close ]
│Open needs (5)
│this session · n1 · maguerrieri/claude-toolbox#272 · 25m
│Why: #208: "status?" answers were rebuilt from scratch each time, so
│sessions now keep a ledger of decisions and needs
│Do PR #272's manual check now that it's merged: run /ledger and confirm
│this need lists under its Why line, then run /ledger resolve n1 and
│confirm it shows as resolved.
│[ Resolve ]
│
│claude-toolbox planning (studio bot) (33110d45) · n1 ·
│maguerrieri/claude-toolbox#319 · 2h
│Why: #208, #316: the ledger shows only through /ledger, so a panel
│would show what sessions need at a glance
│Pick one of the ledger panel options in #319 for #316 to build
│[ Resolve ]
│...
5 open needs this session: Do PR #272's manual check now that it… [ Open ] [ Hide ] [-] │Decisions in this session (2)
```

- **Shows**: every local session's open needs (#316's reader, faked here by
  reading every ledger file), resolved ones on request, this session's
  decisions.
- **Does**: Resolve per need, another session's included (the real one would
  run `ledger.sh resolve <id> --session <session>`).
- **Loudness**: one row while anything is open; Hide until the set changes;
  silent when nothing is open.
- **Costs**: needs #316's reader and session names (`claude agents`, run only
  while another session has an open need, at most once a minute). Every
  terminal session polls the ledger directory (every 15 seconds here). The
  band row competes with other plugins' rows and yields to surveys.

### 4. `inline`: a band row that expands in place

No pane. The same one-row band as option 3, with *Show* in place of *Open*;
*Show* (or `/ledger-pane`, or the chord) expands the band into every open
need, and *Less* folds it back.

```text
5 open needs  [ Less ] [ Hide ]                                                                                                                             [-]
[ Resolve ] this session · n1 · maguerrieri/claude-toolbox#272 · 25m
            Do PR #272's manual check now that it's merged: run /ledger and confirm this need lists under its Why line, then run /ledger resolve n1 and co…
            Why: #208: "status?" answers were rebuilt from scratch each time, so sessions now keep a ledger of decisions and needs
[ Resolve ] claude-toolbox planning (studio bot) (33110d45) · n1 · maguerrieri/claude-toolbox#319 · 2h
            Pick one of the ledger panel options in #319 for #316 to build
            Why: #208, #316: the ledger shows only through /ledger, so a panel would show what sessions need at a glance
[ Resolve ] claude-toolbox #307: model-critique skill (2b5adebb) · n1 · maguerrieri/claude-toolbox#315 · 5h
            Review PR #315, then run /finish-ticket 307 in this session (claude attach 2b5adebb, say finish)
            Why: #307: the model-critique method lives in two places that have drifted, so one skill becomes its home
...
```

- **Shows**: every session's open needs, each cut to one line of text and one
  of Why. No decisions or resolved needs: there's no room.
- **Does**: Resolve per need, with no hotkeys (a digit typed into an empty
  prompt would press one).
- **Loudness**: as option 3 folded; expanded, it takes up to half the
  terminal above the prompt, and a taller list scrolls.
- **Costs**: no pane, so it works the same in the main-screen layout and
  never takes the transcript's width. But long needs are cut, the band holds
  every plugin's rows and every survey, and it can't grow into a place for
  decisions.

## Side by side

| | 1 `pane` | 2 `status` | 3 `band` | 4 `inline` |
| --- | --- | --- | --- | --- |
| Toggle | command, chord | command, chord | Open, command, chord | Show/Less, command, chord |
| Closed by | toggle, Esc, `✕`, `ctrl+x x` | as 1 | toggle, `✕`, `ctrl+x x` | Less, toggle |
| Lives in | pane | status line + pane | band row + pane | band |
| Scope | this session | this session | every session | every session |
| Decisions | yes | yes | this session's | no |
| Resolved needs | on request | on request | on request | no |
| Resolve | yes | yes | yes, any session's | yes, any session's |
| Visible unasked | no | one line, can't hide | one row, Hide until it changes | one row, Hide until it changes |
| Needs #316's reader | no | no | yes | yes |

## Recommendation

**Build option 3 (`band`) in #316.** #316 exists so the owner sees what *every*
session needs without asking each, which rules out options 1 and 2, and a
quiet signal is what gets a waiting need noticed, which an on-demand pane
alone doesn't give. Between 3 and 4, the band row is the same; 3 adds a pane
with room for whole needs, their Why lines and this session's decisions,
while 4 cuts every need to a line and shares the band with surveys and other
plugins. Outside the fullscreen layout the API seats a pane above the prompt
instead of docking it (not tried here), so 3 should still work there.

Keep from the other options:

- the one toggle command (`/ledger-pane`) that opens and closes, plus a line
  in the plugin's docs suggesting a `command:ledger-pane` chord, since the
  plugin can't bind one itself;
- *Show resolved* in the pane;
- no digit hotkeys on Resolve, in the band or the pane.

Questions for the owner:

1. **Which option should #316 build?** The recommendation is 3.
2. **Should the panel resolve another session's need?** The mock allows it,
   as PR #272's mod did. The recommendation is yes: a need is a request to the
   owner, so dismissing it is the owner's call wherever it was recorded, and
   FINISH's own `resolve --ref` closes hand-back needs anyway.
3. **Should Esc close the pane?** The recommendation is no for option 3,
   whose pane is a sidebar left open; yes if the owner picks 1 or 2.

## What the mocks don't settle

- Only the terminal's fullscreen layout was driven by hand. The tests draw
  each option's tree for the terminal and the desktop app, but the desktop
  app's widget seat and the main-screen layout (where a pane opens inline
  above the prompt) weren't looked at.
- The mock reads every ledger file itself. #316's `list --all` and its error
  handling (an unreadable ledger, a hanging `claude agents`) are #316's, as
  the session-ledger design's *Deferred to #316* says.
- Once the owner picks, record the choice on #316. (They picked option 4,
  above.)
