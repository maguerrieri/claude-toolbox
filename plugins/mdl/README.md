# mdl

`/mdl big`, `/mdl medium` and `/mdl small` switch the session's model and
effort level in one command, where it otherwise takes two (`/model`, then
`/effort`). Each size is a preset you set: a model and an effort level.

It's a mod (a plugin of function hooks), so it needs a Claude Code build with
the mod API; it was written and tested against 2.1.325.

## Install

At the prompt of a terminal session:

```
/plugin install mdl --marketplace maguerrieri/claude-toolbox
```

Or from a shell:

```
claude plugin marketplace add maguerrieri/claude-toolbox
claude plugin install mdl@maguerrieri-toolbox
```

It isn't one of `defaults`' dependencies, so installing `defaults` doesn't
bring it in.

## Set the presets

The plugin ships no presets: until you set a size, `/mdl <size>` says it
isn't configured and which fields to set. Each size has two fields:

| Field | What it takes |
| --- | --- |
| `bigModel`, `mediumModel`, `smallModel` | A model as `/model` takes it: an alias (`opus`, `sonnet`, `haiku`, `fable`, `opus[1m]` for the 1M context) or a full model ID |
| `bigEffort`, `mediumEffort`, `smallEffort` | An effort level as `/effort` takes it: `low`, `medium`, `high`, `xhigh`, `max`, or `auto` (the model's own default) |

Set them in `/config` (the rows are `mdl.bigModel` and so on), or in your
user settings:

```json
{
  "pluginConfigs": {
    "mdl@maguerrieri-toolbox": {
      "options": {
        "bigModel": "opus",
        "bigEffort": "high",
        "mediumModel": "sonnet",
        "mediumEffort": "medium",
        "smallModel": "haiku",
        "smallEffort": "low"
      }
    }
  }
}
```

Those values are an example, not a recommendation. A plugin loaded with
`--plugin-dir` reads its options under `pluginConfigs.mdl` instead.

## Use

- `/mdl <size>` runs `/model <model>`, then `/effort <effort>`. Each prints its
  own line, as if you had typed it.
- `/mdl` alone lists the three sizes, what each is set to, and the model the
  session is on. It changes nothing.
- An unknown size, an unset field, or an effort that isn't a level changes
  nothing, and the reply says what's wrong.
- A model `/model` refuses (one it doesn't know, or one your account can't use
  yet) leaves the effort alone too: `/model` prints why, and `/mdl` adds a line
  saying the effort wasn't changed. Mid-conversation, `/model` may ask you to
  confirm the switch, since the new model re-reads the whole history; answer
  no and the effort stays as it was as well.
- Two `/mdl` in a row run in order: the first one's `/model` and `/effort`,
  then the second's.

**The switch applies from your next message.** A command can't run another
command while it runs, so `/mdl` answers first and `/model` and `/effort`
follow straight after, once the session is idle. Typed while a turn is
running, `/mdl` answers at once and runs `/model` when the turn ends, ahead of
any message you type after it. `/effort` can only follow once `/model` has
switched, so a message you queue during that turn runs on the new model at the
old effort. To be sure of both, wait for `/effort`'s line before you send it.

**It saves what `/model` and `/effort` save.** Typing those commands makes the
model your default for new sessions, and the effort the default for that model
(all but `max`, which lasts for the session only). `/mdl` runs the same
commands, so it does the same.

## How it works

`hooks/register.ts` registers `/mdl` at session start and answers it in a
`command.run` hook. That hook can't call `$.command.run` itself: the engine
refuses, since the run would wait on the command the hook is holding. So the
hook replies, and a `$.clock.after(0, …)` timer runs `/model`, checks that the
model took, and only then runs `/effort`. `/model`'s result carries no text, so
the check reads the `PostModelSwitch` event, which fires only when the model
really changes. With none, the session was either already on that model (its
model ID, or a model of the family an alias such as `opus` names) or `/model`
refused it. `/effort` has to wait for that answer, since a plugin's own
`command.run` hooks don't see the commands it runs, so it can't queue both and
hold `/effort` back from a hook.

`claude plugin test plugins/mdl` runs `tests/mdl.test.ts`, which stands in for
the engine beneath the plugin. CI runs it and `claude plugin validate`
(`.github/workflows/mdl-ci.yml`).
