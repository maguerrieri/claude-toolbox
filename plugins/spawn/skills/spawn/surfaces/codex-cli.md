# Codex surface: CLI

The selected target is a durable nonblocking Codex CLI job. Stock Codex CLI
supports `codex exec`, but it does not currently expose a durable background
session launcher equivalent to Claude Code's `claude --bg`. Running `codex exec`
inline or shell-backgrounding it would violate spawn's durable, inspectable,
hand-back contract.

Report that the selected `codex+cli` pair lacks a supported durable background
launcher in this runtime and stop. Do not call Codex desktop task tools, Codex
cloud, `claude --bg`, or an in-session subagent as a substitute. If a future
runtime exposes a native durable Codex CLI launcher, use only its documented
stable identifier and attach/inspect controls.
