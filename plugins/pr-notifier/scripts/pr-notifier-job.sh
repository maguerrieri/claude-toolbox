#!/bin/sh
# pr-notifier's launchd job (#295). The install copies this file to
# ~/.local/libexec/pr-notifier-job, and the job's plist runs it every 60
# seconds, as the user whose sessions the notifier serves. Each run:
#
#   1. rotates job.log and notifier.log once either passes 1 MiB (one old
#      copy is kept, as <log>.1), then sends its own output to job.log, and
#      records the run's outcome in job.last;
#   2. unlocks that user's default keychain, whose password is empty
#      (maguerrieri/claude-config#132, #144), and skips the run if that
#      fails: claude finds no login in a locked keychain;
#   3. sets PATH to the install's wake_path from config.json, since that PATH
#      becomes every woken session's tool PATH (the spike's Trap 2), and
#      skips the run if there is none;
#   4. runs "$HOME/.local/bin/pr-notifier" check, from /, with no
#      CLAUDE_CONFIG_DIR (each subscription carries its own: the spike's
#      Trap 3).
#
# launchd opens no file for this job (its plist has no StandardOutPath or
# StandardErrorPath): it redirects its own output, as its own user, so a
# LaunchDaemon's root never writes into a directory that user controls.
#
# Test seams: PR_NOTIFIER_HOME (the state directory, as for the CLI) and
# PR_NOTIFIER_SECURITY (replaces /usr/bin/security).
set -u

if [ "$(id -u)" = 0 ]; then
	echo "pr-notifier-job: refusing to run as root; its plist must name the user (UserName)" >&2
	exit 1
fi

state=${PR_NOTIFIER_HOME:-$HOME/.local/state/pr-notifier}
cli=$HOME/.local/bin/pr-notifier
security=${PR_NOTIFIER_SECURITY:-/usr/bin/security}
max_log=1048576

mkdir -p "$state" || exit 1

rotate() { # rotate <log>: past $max_log bytes, it becomes <log>.1, replacing the old copy
	[ -f "$1" ] || return 0
	size=$(wc -c <"$1" | tr -d ' ')
	[ "${size:-0}" -gt "$max_log" ] || return 0
	mv -f "$1" "$1.1"
}
rotate "$state/job.log"
rotate "$state/notifier.log"
exec >>"$state/job.log" 2>&1

# job.last holds this run's outcome, one line, for the install's status
# (ran check, check failed, or skipped): a run whose check succeeds logs
# nothing in job.log, so job.log alone can't tell a job that recovered from
# one still failing.
last() {
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >"$state/job.last.tmp" &&
		mv -f "$state/job.last.tmp" "$state/job.last"
}
say() { # a skip: one line in job.log and in job.last
	printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
	last "$*"
}

# The keychain: the user's default one, which is where Claude Code keeps its
# logins. Unlocking an unlocked keychain changes nothing. perl's alarm bounds
# it: a prompt nobody can answer would otherwise hang the job.
if [ -x "$security" ]; then
	keychain=$("$security" default-keychain -d user 2>/dev/null |
		sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | head -n 1)
	if [ -n "$keychain" ] && [ -e "$keychain" ]; then
		if ! out=$(/usr/bin/perl -e 'alarm 30; exec @ARGV' "$security" unlock-keychain -p '' "$keychain" 2>&1); then
			say "skipped: couldn't unlock $keychain, so claude would find no login: $(printf '%s' "$out" | head -n 1)"
			exit 1
		fi
	fi
fi

# The PATH: config.json's wake_path, which the install captured from the
# user's login shell. No fallback: a PATH guessed here would stay with every
# session this run wakes.
jq=$(PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin command -v jq) || jq=
wake_path=
if [ -n "$jq" ] && [ -f "$state/config.json" ]; then
	wake_path=$("$jq" -r '.wake_path // empty | strings' "$state/config.json" 2>/dev/null) || wake_path=
fi
if [ -z "$wake_path" ]; then
	say "skipped: no wake_path in $state/config.json (or no jq to read it); run the install"
	exit 1
fi
PATH=$wake_path
export PATH

if [ ! -x "$cli" ]; then
	say "skipped: $cli is missing; run the install"
	exit 1
fi

unset CLAUDE_CONFIG_DIR CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID
cd / || exit 1
"$cli" check
rc=$?
if [ "$rc" = 0 ]; then
	last "ran check"
else
	last "check failed: exit $rc (see job.log)"
fi
exit "$rc"
