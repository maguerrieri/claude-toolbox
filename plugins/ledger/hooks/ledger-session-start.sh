#!/usr/bin/env bash
# SessionStart — hand the plugin root to Bash commands, and reap old ledgers.
#
# 1. Export CLAUDE_LEDGER_ROOT, which the docs run scripts/ledger.sh from.
#    Only a hook knows CLAUDE_PLUGIN_ROOT, and CLAUDE_ENV_FILE is writable
#    from SessionStart only. ledger.sh keys the ledger on the harness's
#    CLAUDE_CODE_SESSION_ID; on a CLI that doesn't set it (before 2.1.132),
#    export CLAUDE_SESSION_ID too, as ticket-workflow's hook does, so the
#    ledger works without that plugin. (A child launched from the Bash tool
#    inherits that export; the spawn edges strip it.)
#
# 2. Opportunistic GC: ledgers outlive their sessions and nothing else reaps
#    them. Delete those untouched for 30 days that hold no open need, after
#    touching this session's own so a still-live session doesn't lose an old
#    one. A ledger with an open need is kept for 90 days: its session may be
#    resumed after a month away, and the need is still the owner's to answer.
#    Past that it goes too, since a need no session can resolve (a child's
#    hand-back whose PR another session landed; resolving it from there is
#    #316) would otherwise keep its ledger forever. Only in the default
#    location: an overridden directory (test scaffolding, or a misconfigured
#    broad path) must never have its contents deleted by this hook.
#
# Fails open: this hook must never block a session from starting.
set -uo pipefail

input=$(cat)

# The session id, read with a bash regex: only a plain token may name a file.
session_id=
id_re='"session_id"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)"'
if [[ $input =~ $id_re ]]; then
	case "${BASH_REMATCH[1]}" in
	. | *..*) ;;
	*) session_id=${BASH_REMATCH[1]} ;;
	esac
fi

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
	{
		[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] &&
			printf 'export CLAUDE_LEDGER_ROOT=%q\n' "$CLAUDE_PLUGIN_ROOT"
		[ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || [ -z "$session_id" ] ||
			printf 'export CLAUDE_SESSION_ID=%q\n' "$session_id"
	} >>"$CLAUDE_ENV_FILE" 2>/dev/null || true
fi

[ -z "${CLAUDE_SESSION_LEDGER_DIR:-}" ] && [ -n "${HOME:-}" ] || exit 0
dir="$HOME/.claude/session-ledger"
[ -d "$dir" ] || exit 0

# Everything below runs under the directory's lock, the one every write holds
# from its read to its rename, when it can be had within two seconds (perl
# takes it). Unlocked, another session's reaping could pick this session's old
# ledger, this session could then refresh it, and the delete would still take
# it; or the reaping could check a ledger's age, a write could then add to it
# and rename it into place, and the delete would take the new entry with the
# old ones.
locked=no
if command -v perl >/dev/null 2>&1 && { exec 9>>"$dir/.lock"; } 2>/dev/null &&
	perl -MFcntl=:flock -e 'open(my $fh, ">&=", 9) or exit 2;
		for (1 .. 40) { exit 0 if flock($fh, LOCK_EX | LOCK_NB); select(undef, undef, undef, 0.05) }
		exit 1' 2>/dev/null; then
	locked=yes
fi

# This session's own ledger is refreshed first, under the lock when it was
# had, so another session's reaping sees it fresh or not at all. Without the
# lock the refresh still runs, since a resumed session must not lose its
# ledger to a lock it couldn't take; the reaping then checks each ledger's age
# again just before deleting it, which leaves only that instant open.
[ -z "$session_id" ] || [ ! -f "$dir/$session_id.jsonl" ] || touch "$dir/$session_id.jsonl" 2>/dev/null

# A ledger with no open need, or a temp file a killed write left behind
# (`.<ledger>.XXXXXX`), reaped only under the lock; without it, or without
# jq, the reaping skips its turn (it's opportunistic). Each ledger's age and
# open needs are checked again just before it's deleted. The lock file
# itself, `.lock`, matches neither pattern and is never reaped: deleting a
# lock file a writer has just opened would let the next writer lock a new
# file at the same path.
[ "$locked" = yes ] && command -v jq >/dev/null 2>&1 || exit 0
# An open need is one ledger.sh counts as one: is-entry.jq, which it reads too.
hook_dir=${BASH_SOURCE[0]%/*}
[ "$hook_dir" != "${BASH_SOURCE[0]}" ] || hook_dir=.
entry_def=$(cat "$hook_dir/../scripts/is-entry.jq" 2>/dev/null) || exit 0
find "$dir" -maxdepth 1 -type f -name '.*.jsonl.*' -mtime +30 -delete 2>/dev/null || true
find "$dir" -maxdepth 1 -type f -name '*.jsonl' -mtime +30 -print0 2>/dev/null |
	while IFS= read -r -d '' ledger; do
		[ -n "$(find "$ledger" -maxdepth 0 -type f -mtime +30 2>/dev/null)" ] || continue
		# Kept, until it's 90 days old, when it has an open need, and always
		# when it can't be read to tell.
		open=$(jq -R "$entry_def"' fromjson? // empty | select(is_entry and .kind == "need" and .resolved_at == null) | 1' "$ledger" 2>/dev/null) ||
			continue
		if [ -n "$open" ] && [ -z "$(find "$ledger" -maxdepth 0 -type f -mtime +90 2>/dev/null)" ]; then
			continue
		fi
		rm -f "$ledger"
	done
exec 9>&-
