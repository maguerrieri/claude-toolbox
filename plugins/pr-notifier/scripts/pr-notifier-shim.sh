#!/bin/sh
# pr-notifier's stable path. The install (#295) copies this file to
# ~/.local/bin/pr-notifier, the one path sessions and the launchd job call,
# since the plugin's own directory carries its version and moves on update.
#
# It runs the newest pr-notifier installed in any of this user's Claude config
# roots (~/.claude, ~/.claude-*), so a plugin update needs no reinstall.
# PR_NOTIFIER_ROOT pins a plugin directory instead (a checkout, or a test).
set -u

if [ -n "${PR_NOTIFIER_ROOT:-}" ]; then
	exec bash "$PR_NOTIFIER_ROOT/bin/pr-notifier" "$@"
fi

newest=$(
	for cli in "$HOME"/.claude/plugins/cache/maguerrieri-toolbox/pr-notifier/*/bin/pr-notifier \
		"$HOME"/.claude-*/plugins/cache/maguerrieri-toolbox/pr-notifier/*/bin/pr-notifier; do
		[ -f "$cli" ] || continue
		version=${cli%/bin/pr-notifier}
		printf '%s %s\n' "${version##*/}" "$cli"
	done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1 | cut -d' ' -f2-
)
if [ -z "$newest" ]; then
	echo "pr-notifier: no installed pr-notifier plugin found under $HOME/.claude*/plugins/cache" >&2
	exit 127
fi
exec bash "$newest" "$@"
