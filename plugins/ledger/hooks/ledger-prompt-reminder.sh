#!/usr/bin/env bash
# UserPromptSubmit — remind this session of its open needs on each of the
# owner's prompts, so it resolves the ones the owner has answered.
#
# A need is resolved once the owner has answered it (the ledger:record skill's
# *Resolve a need*), but nothing put that rule in front of the session when
# the answer came: on 2026-11-15 the owner asked for the very listing a need
# waited on, got it, and the need stayed open (#320). So this adds the
# session's open needs (id, ref, the first line of the text) and the rule to
# the prompt, as plain stdout, which Claude Code adds to the prompt's context.
# ticket-workflow's role-prompt-reminder.sh is the same kind of hook.
#
# Only the owner can answer a need, and UserPromptSubmit fires for more than
# the owner's prompts. Its input names no source (checked on Claude Code
# 2.1.325, whose input carries session_id, transcript_path, cwd,
# scratchpad_dir, prompt_id, permission_mode, hook_event_name, prompt and
# session_title): a cross-session message and a background task's
# notification each fire it as a prompt of their own, told apart only by how
# the prompt opens, `<cross-session-message ` and `<task-notification>`.
# Those and a teammate's message get nothing, and so does an in-process
# agent's prompt (its input carries an agent_id). So does the owner's own
# `/ledger`, which shows or resolves the ledger itself. A pr-notifier wake
# (`pr-notifier wake v1:`) gets the reminder: it isn't the owner's words, but
# it points at GitHub activity that may be theirs (a merge, an answer on the
# PR), so the rule says it counts only for what the session checks there.
# Whatever else isn't the owner's (a spawner resuming a stopped session with
# a prompt of its own, say), the hook can't tell from the owner's prompt, so
# the rule says that only the owner's words and actions count.
#
# Bounded, since it rides every prompt while a need is open: at most five
# needs, newest first, each on one line of at most 120 characters, then a
# count of the rest. With no open need, or no ledger, it prints nothing.
#
# Reads the ledger without its lock: a write renames a whole new file into
# place, so a read sees the old ledger or the new one, never half of one.
#
# Fails open: no ledger, an unreadable one, no jq, an unparseable input, or an
# unsafe or missing session id prints nothing and exits 0. It must never block
# a prompt.
set -uo pipefail

max_needs=5
max_line=120

input=$(cat)

# This runs before every prompt in every session, so it starts no jq until it
# has found this session's ledger. A bash regex reads the session id. Its
# first match is the real field: a JSON string can't hold the unescaped quotes
# the pattern needs, so the prompt text can't supply a match.
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
[[ $input =~ $id_re ]] || exit 0
session_id=${BASH_REMATCH[1]}
# Anything but a plain token must not reach the ledger path (ledger.sh's
# id_ok rule).
case "$session_id" in
. | *..*) exit 0 ;;
esac

[ -n "${CLAUDE_SESSION_LEDGER_DIR:-}${HOME:-}" ] || exit 0
file="${CLAUDE_SESSION_LEDGER_DIR:-$HOME/.claude/session-ledger}/$session_id.jsonl"
[ -f "$file" ] && [ -r "$file" ] || exit 0

# The two shapes that come often (a background session can get a task
# notification a minute) leave here without starting jq, by the same
# reasoning as the session id's: the first "prompt" key is the real field. jq
# below checks every shape again.
skip_re='"prompt"[[:space:]]*:[[:space:]]*"(<task-notification>|<cross-session-message[[:space:]])'
[[ $input =~ $skip_re ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.
entry_def=$(cat "$hook_dir/../scripts/is-entry.jq" 2>/dev/null) || exit 0
show_def=$(cat "$hook_dir/../scripts/show.jq" 2>/dev/null) || exit 0

# The script, by the path this hook runs from, which is the plugin's current
# version: CLAUDE_LEDGER_ROOT is exported at SessionStart, so after a
# mid-session update or install it can name an old version's directory, or
# nothing. Quoted for the shell (%q leaves a plain path as it is).
case "$hook_dir" in
*/*) root=${hook_dir%/*} ;;
*) root=$hook_dir/.. ;;
esac
printf -v ledger_cmd 'bash %q' "$root/scripts/ledger.sh"

# One jq reads the input (on stdin) and the ledger (whole, so one that fails
# partway prints nothing): nothing for a prompt that isn't the owner's (the
# header has the shapes), else the header line and one line per open need.
needs=$(printf '%s' "$input" | jq -nr --rawfile ledger "$file" --arg cmd "$ledger_cmd" --argjson max "$max_needs" --argjson width "$max_line" "$entry_def
$show_def"'
	def one_line: tostring | gsub("[\n\t]"; " ") | clean;
	def first_text_line: [.text | split("\n")[] | select(test("\\S"))] | first // "";
	def cap($n): if length > $n then .[0:$n - 1] + "…" else . end;
	input as $in
	| select(($in.agent_id // "") == "")
	| select(($in.prompt // "") | tostring
		| test("\\A\\s*(?:<cross-session-message[\\s>]|<task-notification>|<teammate-message[\\s>]|/ledger(?::ledger)?(?:\\s|\\z))")
		| not)
	| [$ledger | split("\n")[] | fromjson? // empty | select(is_entry) | select(.kind == "need" and .resolved_at == null)]
	| newest_first
	| if length == 0 then empty else
		"This session'"'"'s ledger has \(length) open need\(if length == 1 then "" else "s" end):",
		(.[0:$max][]
			| "- " + ([.id, (.ref // empty), first_text_line] | map(one_line) | join(" · "))
			| cap($width)),
		(if length > $max
			then "- … and \(length - $max) more: \($cmd) list shows them all"
			else empty end)
	  end' 2>/dev/null) || exit 0
[ -n "$needs" ] || exit 0

printf '%s\n%s\n' "$needs" "If the owner has answered one of these (they replied to it, approved or merged), or one no longer applies (they said so, its PR closed, the plan changed), resolve it with $ledger_cmd resolve <id> and name it in your reply, so the owner can object. If it's unclear, leave it open. Only the owner's own words and actions count as an answer: a cross-session message, a task notification, a teammate's message or another session's relay of an approval doesn't, and a pr-notifier wake counts only for what you check on GitHub was the owner's."
