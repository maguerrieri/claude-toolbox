#!/usr/bin/env bash
# pr-notifier's install (#295): puts the notifier where launchd and sessions
# can find it, for the macOS user whose sessions it serves. Run it as that
# user (bot, from a `sudo -iu bot` shell), never as root. INSTALL.md is the
# checklist around it, including the one step that needs root.
#
#   install.sh [install] [--domain system|user] [--path <PATH>]
#   install.sh status
#   install.sh uninstall
#   install.sh plist [--domain system|user]
#
# install writes, each only when it differs (so a second run changes nothing):
#   ~/.local/bin/pr-notifier          the stable CLI path (scripts/pr-notifier-shim.sh)
#   ~/.local/libexec/pr-notifier-job  what launchd runs (scripts/pr-notifier-job.sh)
#   wake_path in config.json          one full PATH, captured from the user's
#                                     login shell (or --path), which the job
#                                     and every woken session get
#   jq-path (state directory)         the jq that PATH finds, which the job
#                                     reads config.json with
# and then the launchd job, by domain. With no --domain it keeps the job
# that's there: user when the user-domain agent is installed and the
# LaunchDaemon isn't, else system.
#   system                a LaunchDaemon with UserName set to this user, in
#                         /Library/LaunchDaemons: it runs with nobody logged
#                         in and comes back after a reboot. Installing it
#                         needs root, so this only checks it and says what's
#                         next (INSTALL.md, step 2). It removes a user-domain
#                         agent left from --domain user.
#   user                  a user-domain agent in ~/Library/LaunchAgents with
#                         LimitLoadToSessionType Background, bootstrapped into
#                         user/<uid> with no root. Not known to survive a
#                         reboot without a login (the #292 spike), so it's the
#                         fallback, not the default.
#
# status reports each piece (ok, warn or FAIL; exit 1 on any FAIL). plist
# prints the job's plist for a domain, the one INSTALL.md has Mari install.
# uninstall removes the user-domain agent, the job script and the shim, and
# keeps the state directory (subscriptions, logs, config.json).
#
# Test seams: PR_NOTIFIER_HOME (the state directory, as for the CLI),
# PR_NOTIFIER_LAUNCHCTL (replaces launchctl), PR_NOTIFIER_SECURITY (replaces
# /usr/bin/security) and PR_NOTIFIER_DAEMON_DIR (replaces
# /Library/LaunchDaemons).
set -uo pipefail

label=works.sprue.bot.pr-notifier
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
shim_src=$here/pr-notifier-shim.sh
job_src=$here/pr-notifier-job.sh

state=${PR_NOTIFIER_HOME:-$HOME/.local/state/pr-notifier}
config=$state/config.json
jq_path=$state/jq-path
shim=$HOME/.local/bin/pr-notifier
job=$HOME/.local/libexec/pr-notifier-job
agent=$HOME/Library/LaunchAgents/$label.plist
daemon=${PR_NOTIFIER_DAEMON_DIR:-/Library/LaunchDaemons}/$label.plist
launchctl=${PR_NOTIFIER_LAUNCHCTL:-launchctl}
security=${PR_NOTIFIER_SECURITY:-/usr/bin/security}
uid=$(id -u)
user=$(id -un)
login_shell=${SHELL:-/bin/zsh}
# The plist's own PATH only has to find what the job script runs before it
# switches to wake_path (id, mkdir, wc, mv, date, sed).
plist_path=/usr/bin:/bin:/usr/sbin:/sbin

usage() {
	cat >&2 <<'USAGE_EOF'
usage: install.sh [install] [--domain system|user] [--path <PATH>]
       install.sh status
       install.sh uninstall
       install.sh plist [--domain system|user]
USAGE_EOF
	exit 2
}

die() {
	echo "install.sh: $*" >&2
	exit 1
}

run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/pr-notifier-install.XXXXXX") || die "can't make a temp directory"
trap 'rm -rf "$run_tmp"' EXIT

# --- the plist --------------------------------------------------------------

# Everything the plist interpolates is checked against this, so it needs no
# XML escaping and holds no surprises for launchd.
plain() { [[ $1 =~ ^[A-Za-z0-9._/-]+$ ]]; }

render_plist() { # render_plist <system|user>: the job's plist on stdout
	local who
	plain "$HOME" && plain "$user" && plain "$login_shell" ||
		die "HOME ($HOME), the user ($user) or SHELL ($login_shell) has a character the plist can't carry"
	if [ "$1" = system ]; then
		# A LaunchDaemon runs as root unless it names its user.
		who="  <key>UserName</key>
  <string>$user</string>"
	else
		# The user domain loads an agent only into a session type it names,
		# and bot has no GUI session (the spike).
		who="  <key>LimitLoadToSessionType</key>
  <string>Background</string>"
	fi
	cat <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$label</string>
$who
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$job</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>$HOME</string>
    <key>USER</key>
    <string>$user</string>
    <key>LOGNAME</key>
    <string>$user</string>
    <key>SHELL</key>
    <string>$login_shell</string>
    <key>LANG</key>
    <string>en_US.UTF-8</string>
    <key>PATH</key>
    <string>$plist_path</string>
  </dict>
  <key>WorkingDirectory</key>
  <string>/</string>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>60</integer>
  <key>AbandonProcessGroup</key>
  <true/>
</dict>
</plist>
PLIST_EOF
}

same_plist() { # same_plist <a> <b>: byte for byte, else as parsed (a paste can change whitespace)
	cmp -s "$1" "$2" && return 0
	command -v plutil >/dev/null 2>&1 || return 1
	cmp -s <(plutil -convert xml1 -o - "$1" 2>/dev/null) <(plutil -convert xml1 -o - "$2" 2>/dev/null)
}

# --- launchctl --------------------------------------------------------------

loaded() { "$launchctl" print "$1" >/dev/null 2>&1; } # loaded <domain>/<label>

unload() { # unload <domain>/<label>: boots it out and waits until it's gone
	local i
	"$launchctl" bootout "$1" >/dev/null 2>&1 || true
	# bootout returns before launchd is done, and a bootstrap too soon after
	# fails; launchd gives a job 20 seconds to exit after SIGTERM.
	for i in $(seq 1 300); do
		loaded "$1" || return 0
		sleep 0.1
	done
	echo "install.sh: $1 is still loaded" >&2
	return 1
}

job_info() { # job_info <domain>/<label>: "state=… runs=… last-exit=…", or nothing if it isn't loaded
	# The service's own fields are indented one tab; nested blocks (its
	# endpoints, say) have state lines of their own, a tab deeper.
	local tab
	tab=$(printf '\t')
	"$launchctl" print "$1" 2>/dev/null | sed -n \
		-e "s/^${tab}state = \(.*\)\$/state=\1/p" \
		-e "s/^${tab}runs = \(.*\)\$/runs=\1/p" \
		-e "s/^${tab}last exit code = \(.*\)\$/last-exit=\1/p" | paste -sd' ' -
}

# --- files ------------------------------------------------------------------

put() { # put <source> <destination>: copies it (mode 755) when it differs
	mkdir -p "$(dirname "$2")" || die "can't create $(dirname "$2")"
	if [ -f "$2" ] && cmp -s "$1" "$2"; then
		chmod 755 "$2"
		echo "ok: $2 is current"
		return
	fi
	cp "$1" "$2.install.$$" && chmod 755 "$2.install.$$" && mv -f "$2.install.$$" "$2" ||
		die "can't write $2"
	echo "wrote $2"
}

capture_path() { # the PATH a fresh login shell of this user gets, from $HOME
	# Interactive as well as login, so it gets what zshrc adds: a `sudo -iu
	# bot` shell, where sessions start, is both. A marker line keeps out
	# whatever the shell's startup prints, and perl's alarm bounds a startup
	# that waits on input.
	(cd "$HOME" && env -i HOME="$HOME" USER="$user" LOGNAME="$user" SHELL="$login_shell" TERM=dumb \
		/usr/bin/perl -e 'alarm 30; exec @ARGV' "$login_shell" -l -i -c \
		'printf "\n__PR_NOTIFIER_PATH__=%s\n" "$PATH"' </dev/null 2>/dev/null) |
		sed -n 's/^__PR_NOTIFIER_PATH__=//p' | tail -n 1
}

clean_path() { # clean_path <PATH>: its absolute entries, each once, in order
	printf '%s\n' "$1" | tr ':' '\n' | awk '/^\// && !seen[$0]++' | paste -sd: -
}

missing_tools() { # missing_tools <PATH>: the notifier's tools that PATH doesn't find
	local tool
	for tool in claude gh jq bash; do
		PATH=$1 command -v "$tool" >/dev/null 2>&1 || printf '%s ' "$tool"
	done
}

current_wake_path() {
	[ -f "$config" ] || return 0
	jq -r '.wake_path // empty | strings' "$config" 2>/dev/null
}

set_wake_path() { # set_wake_path <PATH>: config.json's wake_path, other keys kept
	local now
	mkdir -p "$state" || die "can't create $state"
	if [ -f "$config" ]; then
		jq -e 'type == "object"' "$config" >/dev/null 2>&1 ||
			die "$config isn't a JSON object; fix or remove it, then run this again"
		now=$(current_wake_path)
		if [ "$now" = "$1" ]; then
			echo "ok: wake_path in $config is current"
			return
		fi
		jq --arg p "$1" '.wake_path = $p' "$config" >"$config.install.$$"
	else
		jq -n --arg p "$1" '{wake_path: $p}' >"$config.install.$$"
	fi && mv -f "$config.install.$$" "$config" || die "can't write $config"
	echo "set wake_path in $config to $1"
}

set_jq_path() { # set_jq_path <PATH>: records the jq that PATH finds, for the job to read config.json with
	local found
	found=$(PATH=$1 command -v jq) || die "no jq on $1"
	if [ -f "$jq_path" ] && [ "$(cat "$jq_path")" = "$found" ]; then
		echo "ok: $jq_path is current"
		return
	fi
	printf '%s\n' "$found" >"$jq_path.install.$$" && mv -f "$jq_path.install.$$" "$jq_path" ||
		die "can't write $jq_path"
	echo "set $jq_path to $found"
}

# --- commands ---------------------------------------------------------------

agent_present() { [ -e "$agent" ] || loaded "user/$uid/$label"; }

parse_domain() { # parse_domain <args...>: sets domain (and wanted_path, for install)
	# With no --domain, keep the job that's there: the user-domain agent when
	# it's installed and the LaunchDaemon isn't, else the LaunchDaemon. So a
	# re-run after an update, or one a status hint suggests, never tears down
	# the fallback's only job.
	if [ ! -e "$daemon" ] && agent_present; then domain=user; else domain=system; fi
	wanted_path=
	while [ $# -gt 0 ]; do
		case $1 in
		--domain)
			[ $# -ge 2 ] || usage
			case $2 in system | user) domain=$2 ;; *) usage ;; esac
			shift 2
			;;
		--path)
			[ $# -ge 2 ] && [ "$cmd" = install ] || usage
			wanted_path=$2
			shift 2
			;;
		*) usage ;;
		esac
	done
}

cmd_install() {
	local raw new_path missing
	[ "$uid" != 0 ] || die "run this as the user whose sessions the notifier serves, not root; INSTALL.md has the one root step"
	command -v jq >/dev/null 2>&1 || die "jq not found on PATH"
	[ -f "$shim_src" ] && [ -f "$job_src" ] || die "can't find the shim or the job script next to $0"
	render_plist "$domain" >"$run_tmp/plist" || exit 1

	if [ -n "$wanted_path" ]; then
		raw=$wanted_path
	else
		raw=$(capture_path)
		[ -n "$raw" ] || die "couldn't read $login_shell's login PATH; pass one with --path"
	fi
	new_path=$(clean_path "$raw")
	missing=$(missing_tools "$new_path")
	[ -z "$missing" ] ||
		die "the PATH to install ($new_path) doesn't find: $missing; install them or pass a PATH that does with --path"

	put "$shim_src" "$shim"
	put "$job_src" "$job"
	set_wake_path "$new_path"
	set_jq_path "$new_path"

	if [ "$domain" = system ]; then
		if agent_present; then
			unload "user/$uid/$label" || die "couldn't boot out the user-domain agent"
			rm -f "$agent" || die "can't remove $agent"
			echo "removed the user-domain agent ($agent): the LaunchDaemon replaces it"
		fi
		if [ ! -e "$daemon" ]; then
			echo "next: the LaunchDaemon isn't installed. Mari installs it as root (INSTALL.md, step 2), then runs: $0 status"
		elif ! same_plist "$run_tmp/plist" "$daemon"; then
			echo "next: $daemon differs from this version's; Mari reinstalls it as root (INSTALL.md, step 2), then runs: $0 status"
		elif ! loaded "system/$label"; then
			echo "next: $daemon is installed but not loaded; Mari loads it as root (INSTALL.md, step 2)"
		else
			echo "ok: the LaunchDaemon $label is installed and loaded"
		fi
		return 0
	fi

	if [ -e "$daemon" ]; then
		die "the LaunchDaemon ($daemon) is installed, and the two would both run the job; Mari removes it first (INSTALL.md, Uninstall)"
	fi
	if [ -f "$agent" ] && same_plist "$run_tmp/plist" "$agent"; then
		if loaded "user/$uid/$label"; then
			echo "ok: the user-domain agent $label is installed and loaded"
			return 0
		fi
	else
		mkdir -p "$(dirname "$agent")" || die "can't create $(dirname "$agent")"
		unload "user/$uid/$label" || die "couldn't boot out the old agent"
		cp "$run_tmp/plist" "$agent.install.$$" && chmod 644 "$agent.install.$$" &&
			mv -f "$agent.install.$$" "$agent" || die "can't write $agent"
		echo "wrote $agent"
	fi
	"$launchctl" bootstrap "user/$uid" "$agent" || die "launchctl bootstrap user/$uid $agent failed"
	echo "loaded the user-domain agent $label into user/$uid (it runs now, then every 60 seconds)"
}

cmd_status() {
	local fails=0 info wake missing last ts age
	ok() { echo "ok: $*"; }
	warn() { echo "warn: $*"; }
	fail() {
		echo "FAIL: $*"
		fails=$((fails + 1))
	}

	copy() { # copy <installed> <source>
		if [ ! -f "$1" ]; then
			fail "$1 is missing; run: $0"
		elif ! cmp -s "$1" "$2"; then
			warn "$1 differs from this version's ($2); run: $0"
		else
			ok "$1 is current"
		fi
	}
	copy "$shim" "$shim_src"
	copy "$job" "$job_src"

	wake=$(current_wake_path)
	if [ -z "$wake" ]; then
		fail "no wake_path in $config; run: $0"
	else
		missing=$(missing_tools "$wake")
		if [ -n "$missing" ]; then
			fail "wake_path ($wake) doesn't find: $missing"
		else
			ok "wake_path is $wake"
		fi
	fi
	last=
	[ ! -f "$jq_path" ] || last=$(cat "$jq_path")
	if [ -n "$last" ] && [ -x "$last" ]; then
		ok "the job reads config.json with $last"
	else
		warn "no usable jq in $jq_path, so the job looks for one in /usr/bin, /bin, /opt/homebrew/bin and /usr/local/bin; run: $0"
	fi

	render_plist system >"$run_tmp/system" || exit 1
	render_plist user >"$run_tmp/user" || exit 1
	if [ -e "$daemon" ] && agent_present; then
		fail "both the LaunchDaemon ($daemon) and the user-domain agent (user/$uid/$label) are installed; run: $0 (it removes the agent)"
	fi
	loaded_info() { # loaded_info <domain>/<label> <what to run when it isn't loaded>
		info=$(job_info "$1")
		if [ -z "$info" ]; then
			fail "$1 isn't loaded; $2"
		elif [[ $info =~ last-exit=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" != 0 ]; then
			warn "$1 is loaded, and its last run failed: $info (see $state/job.log)"
		else
			ok "$1 is loaded: $info"
		fi
	}
	if [ -e "$daemon" ]; then
		if same_plist "$run_tmp/system" "$daemon"; then
			ok "$daemon matches this version's"
		else
			fail "$daemon differs from this version's (see: $0 plist); Mari reinstalls it (INSTALL.md, step 2)"
		fi
		loaded_info "system/$label" "Mari loads it (INSTALL.md, step 2)"
	elif agent_present; then
		if [ ! -e "$agent" ]; then
			fail "user/$uid/$label is loaded, but $agent is gone; run: $0 --domain user"
		elif same_plist "$run_tmp/user" "$agent"; then
			ok "$agent matches this version's"
		else
			warn "$agent differs from this version's; run: $0"
		fi
		loaded_info "user/$uid/$label" "run: $0"
		warn "the user-domain agent isn't known to come back after a reboot without a login; the LaunchDaemon (INSTALL.md) is the default"
	else
		fail "no launchd job: neither $daemon nor $agent exists (INSTALL.md, steps 1 and 2)"
	fi

	if [ -x "$security" ]; then
		last=$("$security" default-keychain -d user 2>/dev/null | sed -n 's/^[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | head -n 1)
		if [ -z "$last" ] || [ ! -e "$last" ]; then
			warn "no default keychain${last:+ ($last is missing)}, so the job unlocks none"
		else
			ok "the job unlocks the default keychain, $last"
		fi
	fi

	# The job's last run, from job.last (the job script writes it each run).
	last=
	[ ! -f "$state/job.last" ] || last=$(tail -n 1 "$state/job.last")
	if [ -z "$last" ]; then
		warn "the job hasn't run yet (no $state/job.last)"
	else
		ts=${last%% *}
		age=$(jq -nr --arg t "$ts" --argjson now "$(date -u +%s)" '$now - ($t | fromdateiso8601)' 2>/dev/null) || age=
		case $last in
		*" skipped: "*) fail "the job's last run skipped check: $last" ;;
		*" check failed: "*) fail "the job's last check failed: $last" ;;
		*)
			if [ -z "$age" ] || [ "$age" -gt 300 ]; then
				warn "the job's last run was ${age:-?}s ago ($last); it runs every 60 seconds"
			else
				ok "the job's last run: $last"
			fi
			;;
		esac
	fi
	[ ! -s "$state/job.log" ] || echo "the job's log, $state/job.log, ends: $(tail -n 1 "$state/job.log")"

	if [ "$fails" -gt 0 ]; then
		echo "status: $fails FAIL"
		return 1
	fi
	echo "status: ok"
}

cmd_uninstall() {
	[ "$uid" != 0 ] || die "run this as the user whose sessions the notifier serves, not root"
	if [ -e "$daemon" ]; then
		die "the LaunchDaemon ($daemon) is still installed, and would keep running a job that's gone; Mari removes it first (INSTALL.md, Uninstall), then run this again"
	fi
	if [ -e "$agent" ] || loaded "user/$uid/$label"; then
		unload "user/$uid/$label" || die "couldn't boot out the user-domain agent"
		rm -f "$agent" || die "can't remove $agent"
		echo "removed the user-domain agent ($agent)"
	fi
	for f in "$job" "$shim"; do
		if [ -e "$f" ]; then
			rm -f "$f" || die "can't remove $f"
			echo "removed $f"
		fi
	done
	echo "kept $state (subscriptions, logs, config.json); remove it to start over"
}

cmd=${1:-install}
case $cmd in --*) cmd=install ;; *) [ $# -eq 0 ] || shift ;; esac
case $cmd in
install)
	parse_domain "$@"
	cmd_install
	;;
plist)
	parse_domain "$@"
	render_plist "$domain"
	;;
status)
	[ $# -eq 0 ] || usage
	cmd_status
	;;
uninstall)
	[ $# -eq 0 ] || usage
	cmd_uninstall
	;;
*) usage ;;
esac
