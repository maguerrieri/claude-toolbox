#!/usr/bin/env bash
# UserPromptSubmit — remind this session of its open needs on each of the
# owner's prompts, so it resolves the ones the prompt answers.
#
# A need is resolved once the owner has answered it (the ledger:record skill's
# *Resolve a need*), but nothing put that rule in front of the session when
# the answer came: on 2026-11-15 the owner asked for the very listing a need
# waited on, got it, and the need stayed open (#320). So this adds the
# session's open needs (id, ref, the first line of the text) and the rule to
# the prompt, as plain stdout, which Claude Code adds to the prompt's context.
# ticket-workflow's role-prompt-reminder.sh is the same kind of hook.
#
# Only the owner's own prompt can answer a need, and UserPromptSubmit fires
# for more than that. Its input names no source (checked on Claude Code
# 2.1.325, whose input carries session_id, transcript_path, cwd,
# scratchpad_dir, prompt_id, permission_mode, hook_event_name, prompt and
# session_title): a cross-session message and a background task's
# notification each arrive as a prompt of their own, told apart only by how
# the prompt opens, `<cross-session-message ` and `<task-notification>`.
# Those, a teammate's message and a pr-notifier wake (`pr-notifier wake v1:`)
# get nothing, and so does an in-process agent's prompt (its input carries an
# agent_id). Whatever else isn't the owner's, the hook can't tell from the
# owner's prompt, so the reminder says that only the owner's words count.
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
# Anything but a plain token must not reach the ledger path.
case "$session_id" in
. | *..*) exit 0 ;;
esac

[ -n "${CLAUDE_SESSION_LEDGER_DIR:-}${HOME:-}" ] || exit 0
file="${CLAUDE_SESSION_LEDGER_DIR:-$HOME/.claude/session-ledger}/$session_id.jsonl"
[ -f "$file" ] && [ -r "$file" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.
entry_def=$(cat "$hook_dir/../scripts/is-entry.jq" 2>/dev/null) || exit 0
show_def=$(cat "$hook_dir/../scripts/show.jq" 2>/dev/null) || exit 0

# A prompt that isn't the owner's gets nothing (the header has the shapes).
printf '%s' "$input" | jq -e '
	(.agent_id // "") == ""
	and ((.prompt // "") | tostring
		| test("\\A\\s*(?:<cross-session-message[\\s>]|<task-notification>|<teammate-message[\\s>]|pr-notifier wake v1:)")
		| not)' >/dev/null 2>&1 || exit 0

# The open needs, as the header line and one line each. Read in full before
# anything is printed, so a ledger that fails partway prints nothing.
needs=$(jq -nrR --argjson max "$max_needs" --argjson width "$max_line" "$entry_def
$show_def"'
	def one_line: tostring | gsub("[\n\t]"; " ") | clean;
	def first_text_line: [.text | split("\n")[] | select(test("\\S"))] | first // "";
	def cap($n): if length > $n then .[0:$n - 1] + "…" else . end;
	[inputs | fromjson? // empty | select(is_entry) | select(.kind == "need" and .resolved_at == null)]
	| newest_first
	| if length == 0 then empty else
		"This session'"'"'s ledger has \(length) open need\(if length == 1 then "" else "s" end):",
		(.[0:$max][]
			| "- " + ([.id, (.ref // empty), first_text_line] | map(one_line) | join(" · "))
			| cap($width)),
		(if length > $max then "- … and \(length - $max) more (ledger.sh list shows them all)" else empty end)
	  end' "$file" 2>/dev/null) || exit 0
[ -n "$needs" ] || exit 0

printf '%s\n%s\n' "$needs" "If the owner's prompt answers one of these (they replied to it, approved, merged, or said it no longer applies), resolve it with bash \"\${CLAUDE_LEDGER_ROOT:?}/scripts/ledger.sh\" resolve <id> and name it in your reply, so they can object. If it's unclear whether it does, leave it open. Only the owner's own words count: a cross-session message, a task notification or another session's relay is not the owner answering."
