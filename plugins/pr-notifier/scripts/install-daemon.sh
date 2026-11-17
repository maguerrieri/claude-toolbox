#!/bin/bash
# pr-notifier's root step (#295): installs, or removes, the LaunchDaemon that
# runs the notifier's job as bot. Mari runs it, as root, from their OWN
# checkout of this repo on merged main, never from a copy bot can edit: the
# plist it writes decides which user the job runs as. INSTALL.md, step 2.
#
#   install-daemon.sh             install the LaunchDaemon, or reload it if its plist changed
#   install-daemon.sh uninstall   boot it out and remove its plist
#   install-daemon.sh plist       print the plist (needs no root)
#
# It needs root and asks sudo for it. A second run changes nothing. It does
# only this: write /Library/LaunchDaemons/works.sprue.bot.pr-notifier.plist
# (root:wheel 644, as launchd requires) and bootstrap it into the system
# domain. The plist is fixed text, below: nothing in it comes from bot's side,
# and launchd opens no file for the job. scripts/install.sh, run as bot, does
# everything else, and its `status` checks this plist against the same text.
#
# It refuses to run when this file belongs to bot, sits under bot's home, is
# a symbolic link, or is writable by its group or by everyone. Whether the
# checkout holds main's reviewed copy is INSTALL.md step 2's check, made
# before sudo: root running git in a user's repository is its own hazard.
#
# Test seams, honored only when NOT root (as root they are ignored, and it
# always writes the real path with the real launchctl, and guards against
# bot): PR_NOTIFIER_DAEMON_TEST=1 to run without root, and with it
# PR_NOTIFIER_DAEMON_DIR, PR_NOTIFIER_LAUNCHCTL, PR_NOTIFIER_DAEMON_GUARD_USER
# and PR_NOTIFIER_DAEMON_GUARD_HOME.
set -euo pipefail
# Root runs this, so the tools come from the system, not the caller's PATH.
PATH=/usr/bin:/bin:/usr/sbin:/sbin

bot=bot
bot_home=/Users/bot
label=works.sprue.bot.pr-notifier
daemons=/Library/LaunchDaemons
launchctl=/bin/launchctl
# Whose files this script refuses to be: bot's. The tests, which bot's own
# sessions run from bot's checkout, name another user here.
guard_user=$bot
guard_home=$bot_home
testing=
if [ "$(id -u)" != 0 ] && [ "${PR_NOTIFIER_DAEMON_TEST:-}" = 1 ]; then
	testing=1
	daemons=${PR_NOTIFIER_DAEMON_DIR:-$daemons}
	launchctl=${PR_NOTIFIER_LAUNCHCTL:-$launchctl}
	guard_user=${PR_NOTIFIER_DAEMON_GUARD_USER:-$guard_user}
	guard_home=${PR_NOTIFIER_DAEMON_GUARD_HOME:-$guard_home}
fi
plist=$daemons/$label.plist

die() {
	echo "install-daemon.sh: $*" >&2
	exit 1
}

print_plist() {
	cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
  <key>UserName</key>
  <string>$bot</string>
  <key>SessionCreate</key>
  <true/>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$bot_home/.local/libexec/pr-notifier-job</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$bot_home</string>
    <key>USER</key>
    <string>$bot</string>
    <key>LOGNAME</key>
    <string>$bot</string>
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
  <integer>15</integer>
  <key>AbandonProcessGroup</key>
  <true/>
</dict>
</plist>
PLIST_EOF
}

cmd=${1:-install}
[ $# -le 1 ] || die "usage: $0 [install|uninstall|plist]"
case $cmd in
plist)
	print_plist
	exit 0
	;;
install | uninstall) ;;
*) die "usage: $0 [install|uninstall|plist]" ;;
esac

self_dir=$(cd "$(dirname "$0")" && pwd -P)
self=$self_dir/$(basename "$0")

# This file is about to run as root, so it must not be one bot can edit.
# GNU's form first: given BSD's -f, GNU stat prints filesystem details before
# failing, where BSD stat given -c prints nothing (the tests run on Linux too).
[ ! -L "$0" ] && [ ! -L "$self" ] || die "$0 is a symbolic link; run the file itself, in your own checkout of this repo"
owner=$(stat -c %U "$self" 2>/dev/null || stat -f %Su "$self")
case $self/ in "$guard_home"/*) die "$self is under $guard_user's home; run the copy in your own checkout of this repo, on merged main" ;; esac
[ "$owner" != "$guard_user" ] || die "$self belongs to $guard_user; run the copy in your own checkout of this repo, on merged main"
# Nor one anybody but its owner can write: -rwxr-xr-x, not -rwxrwxr-x.
mode=$(ls -ld "$self" | cut -c1-10)
case $mode in ?????w???? | ????????w?) die "$self is writable by its group or by everyone ($mode); run a copy only you can write" ;; esac

if [ -z "$testing" ] && [ "$(id -u)" != 0 ]; then
	echo "install-daemon.sh needs root; asking sudo."
	# By full path: sudo looks a bare name up in its own PATH, not here.
	exec sudo "$self" "$@"
fi
cd /

loaded() { "$launchctl" print "system/$label" >/dev/null 2>&1; }

# bootout returns before launchd is done, and a bootstrap too soon after
# fails with "Bootstrap failed: 5"; launchd gives a job 20 seconds to exit.
unload() {
	local i err
	err=$("$launchctl" bootout "system/$label" 2>&1) || true
	for i in $(seq 1 300); do
		loaded || return 0
		sleep 0.1
	done
	die "system/$label is still loaded${err:+ (launchctl bootout said: $err)}"
}

if [ "$cmd" = uninstall ]; then
	if loaded; then
		unload
		echo "booted out system/$label"
	fi
	if [ -e "$plist" ] || [ -L "$plist" ]; then
		rm -f "$plist"
		echo "removed $plist"
	fi
	echo "done; bot's side is removed with: install.sh uninstall (INSTALL.md, Uninstall)"
	exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-notifier-daemon.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
print_plist >"$tmp/plist"

right_owner() { # root:wheel 644 and a plain file, which launchd requires of a daemon's plist
	[ -n "$testing" ] && return 0
	[ ! -L "$plist" ] && [ "$(stat -f '%Su:%Sg %OLp' "$plist")" = "root:wheel 644" ]
}

if [ -f "$plist" ] && cmp -s "$tmp/plist" "$plist" && right_owner; then
	if loaded; then
		echo "ok: $label is installed and loaded; nothing to change"
		exit 0
	fi
	echo "$plist is current but not loaded; loading it"
else
	# The new plist is written beside the old one first, so a failed write
	# leaves the old job running. Then the old job is unloaded, so it's gone
	# before the new plist takes its place.
	[ ! -d "$plist" ] || die "$plist is a directory; move it aside and run this again"
	rm -f "$plist.new"
	if [ -n "$testing" ]; then
		mkdir -p "$daemons"
		cp "$tmp/plist" "$plist.new"
		chmod 644 "$plist.new"
	else
		install -m 644 -o root -g wheel "$tmp/plist" "$plist.new"
	fi
	unload
	mv -f "$plist.new" "$plist"
	echo "wrote $plist"
fi
"$launchctl" bootstrap system "$plist"
echo "loaded system/$label (it runs now, then every 15 seconds); check it from a bot shell with: install.sh status"
