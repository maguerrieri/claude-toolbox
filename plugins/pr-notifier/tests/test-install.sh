#!/usr/bin/env bash
# Tests for scripts/install.sh and scripts/pr-notifier-job.sh against stubbed
# launchctl and security: the copies and wake_path, PATH capture and
# cleaning, both launchd domains, idempotence, status, uninstall, the plist
# INSTALL.md has Mari paste, and each run of the job (keychain, PATH, logs).
#
#   bash plugins/pr-notifier/tests/test-install.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
install=$plugin/scripts/install.sh
job_src=$plugin/scripts/pr-notifier-job.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s: expected %s, got %s\n' "$2" "$1" "$3"
	fi
}
has() { # has <file> <fixed string>: "yes" or "no"
	if grep -qF -- "$2" "$1" 2>/dev/null; then echo yes; else echo no; fi
}
same() { if cmp -s "$1" "$2"; then echo yes; else echo no; fi; }

unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID CLAUDE_CONFIG_DIR PR_NOTIFIER_ROOT

STUB=$tmp/stub
mkdir -p "$STUB" "$tmp/bin" "$tmp/tools"
export STUB HOME=$tmp/home PR_NOTIFIER_HOME=$tmp/state
export PR_NOTIFIER_LAUNCHCTL=$tmp/bin/launchctl PR_NOTIFIER_SECURITY=$tmp/bin/security
export PR_NOTIFIER_DAEMON_DIR=$tmp/daemons SHELL=/bin/zsh
mkdir -p "$HOME" "$PR_NOTIFIER_DAEMON_DIR"
uid=$(id -u)
label=works.sprue.bot.pr-notifier

# launchctl: a target is loaded while $STUB/loaded/<target with / as _> exists.
cat >"$tmp/bin/launchctl" <<'LAUNCHCTL_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/launchctl.log"
mkdir -p "$STUB/loaded"
key() { printf '%s' "$1" | tr '/' '_'; }
case $1 in
print)
	[ -f "$STUB/loaded/$(key "$2")" ] || { echo "Could not find service" >&2; exit 113; }
	printf '%s = {\n\tstate = running\n\truns = 3\n\tlast exit code = %s\n}\n' "$2" "$(cat "$STUB/exit" 2>/dev/null || echo 0)"
	;;
bootstrap) touch "$STUB/loaded/$(key "$2/works.sprue.bot.pr-notifier")" ;;
bootout) rm -f "$STUB/loaded/$(key "$2")" ;;
*) exit 1 ;;
esac
LAUNCHCTL_EOF

# security: the default keychain is $STUB/kc when $STUB/kc.default exists;
# an unlock exits $STUB/unlock.rc (0 by default).
cat >"$tmp/bin/security" <<'SECURITY_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB/security.log"
case $1 in
default-keychain)
	[ -f "$STUB/kc.default" ] || { echo "security: SecKeychainCopyDefault: A default keychain could not be found." >&2; exit 1; }
	printf '    "%s"\n' "$STUB/kc"
	;;
unlock-keychain)
	rc=$(cat "$STUB/unlock.rc" 2>/dev/null || echo 0)
	[ "$rc" = 0 ] || echo "security: SecKeychainUnlock $4: The user name or passphrase you entered is not correct." >&2
	exit "$rc"
	;;
esac
SECURITY_EOF

# The notifier's tools, for the PATH the install checks: claude and gh are
# stubs, jq and bash the real ones.
printf '#!/bin/sh\nexit 0\n' >"$tmp/tools/claude"
printf '#!/bin/sh\nexit 0\n' >"$tmp/tools/gh"
chmod +x "$tmp/bin/"* "$tmp/tools/"*
tool_path=$tmp/tools:$(dirname "$(command -v jq)"):$(dirname "$(command -v bash)"):/usr/bin:/bin
wake=$(printf '%s\n' "$tool_path" | tr ':' '\n' | awk '!seen[$0]++' | paste -sd: -)

shim=$HOME/.local/bin/pr-notifier
job=$HOME/.local/libexec/pr-notifier-job
agent=$HOME/Library/LaunchAgents/$label.plist
daemon=$PR_NOTIFIER_DAEMON_DIR/$label.plist
out=$tmp/out

reset() {
	rm -rf "$HOME" "$PR_NOTIFIER_HOME" "$STUB" "$PR_NOTIFIER_DAEMON_DIR"
	mkdir -p "$HOME" "$STUB" "$PR_NOTIFIER_DAEMON_DIR"
}
inst() { bash "$install" "$@" >"$out" 2>&1; }
wake_path() { jq -r '.wake_path // "none"' "$PR_NOTIFIER_HOME/config.json" 2>/dev/null || echo none; }
bootstraps() { cat "$STUB/launchctl.log" 2>/dev/null | grep -c '^bootstrap'; }

# --- install, system domain -----------------------------------------------

reset
inst --path "$tool_path"
record 0 "install: exit" "$?"
record yes "install: shim is the plugin's shim" "$(same "$shim" "$plugin/scripts/pr-notifier-shim.sh")"
record yes "install: shim is executable" "$([ -x "$shim" ] && echo yes || echo no)"
record yes "install: job is the plugin's job script" "$(same "$job" "$job_src")"
record "$wake" "install: wake_path is the PATH, cleaned" "$(wake_path)"
record yes "install: says the LaunchDaemon is Mari's next step" "$(has "$out" "next: the LaunchDaemon isn't installed")"
record 0 "install: system domain bootstraps nothing" "$(bootstraps)"

inst --path "$tool_path"
record 0 "second install: exit" "$?"
record no "second install: writes nothing" "$(grep -qE '^(wrote|set) ' "$out" && echo yes || echo no)"
record 3 "second install: three pieces current" "$(grep -c '^ok: .* current' "$out")"

# The PATH: absolute entries only, each once, in order.
reset
inst --path "relative:$tmp/tools::$tmp/tools:$tool_path:."
record 0 "messy PATH: exit" "$?"
record "$wake" "messy PATH: cleaned" "$(wake_path)"

# Other settings survive.
reset
mkdir -p "$PR_NOTIFIER_HOME"
printf '{"idle_grace": 900, "wake_path": "/old"}\n' >"$PR_NOTIFIER_HOME/config.json"
inst --path "$tool_path"
record 900 "config: other keys kept" "$(jq -r .idle_grace "$PR_NOTIFIER_HOME/config.json")"
record "$wake" "config: wake_path replaced" "$(wake_path)"

# A config.json that isn't an object is left alone.
reset
mkdir -p "$PR_NOTIFIER_HOME"
printf 'not json\n' >"$PR_NOTIFIER_HOME/config.json"
inst --path "$tool_path"
record 1 "bad config: exit" "$?"
record "not json" "bad config: untouched" "$(cat "$PR_NOTIFIER_HOME/config.json")"

# A PATH that doesn't find the tools installs nothing.
reset
mkdir -p "$tmp/empty"
inst --path "$tmp/empty"
record 1 "PATH without the tools: exit" "$?"
record yes "PATH without the tools: names them" "$(has "$out" "doesn't find: claude gh jq bash")"
record no "PATH without the tools: no shim" "$([ -e "$shim" ] && echo yes || echo no)"

# --- PATH capture from the login shell -----------------------------------

reset
cat >"$tmp/fakeshell" <<FAKESHELL_EOF
#!/bin/sh
# Stands in for a login shell: noise from its startup, then what -c prints.
echo "welcome, \$USER"
[ "\$1 \$2 \$3" = "-l -i -c" ] || exit 9
PATH="$tool_path:$tmp/tools"
eval "\$4"
FAKESHELL_EOF
chmod +x "$tmp/fakeshell"
SHELL=$tmp/fakeshell inst
record 0 "capture: exit" "$?"
record "$wake" "capture: the login shell's PATH, cleaned" "$(wake_path)"

reset
printf '#!/bin/sh\necho no path here\n' >"$tmp/quietshell"
chmod +x "$tmp/quietshell"
SHELL=$tmp/quietshell inst
record 1 "capture fails: exit" "$?"
record yes "capture fails: suggests --path" "$(has "$out" "pass one with --path")"

# --- the LaunchDaemon's state --------------------------------------------

reset
bash "$install" plist >"$daemon"
inst --path "$tool_path"
record yes "daemon installed, not loaded: says so" "$(has "$out" "is installed but not loaded")"
mkdir -p "$STUB/loaded" && touch "$STUB/loaded/system_$label"
inst --path "$tool_path"
record yes "daemon installed and loaded: ok" "$(has "$out" "ok: the LaunchDaemon $label is installed and loaded")"
sed 's|<integer>60</integer>|<integer>120</integer>|' "$daemon" >"$daemon.new" && mv "$daemon.new" "$daemon"
inst --path "$tool_path"
record yes "daemon differs: says so" "$(has "$out" "differs from this version's")"

# --- install, user domain -------------------------------------------------

reset
inst --domain user --path "$tool_path"
record 0 "user: exit" "$?"
bash "$install" plist --domain user >"$tmp/user.plist"
record yes "user: agent is the user plist" "$(same "$agent" "$tmp/user.plist")"
record yes "user: Background session type" "$(has "$agent" "<string>Background</string>")"
record no "user: no UserName" "$(has "$agent" "UserName")"
record yes "user: bootstrapped into user/<uid>" "$(has "$STUB/launchctl.log" "bootstrap user/$uid $agent")"
inst --domain user --path "$tool_path"
record 1 "user, second run: one bootstrap in all" "$(bootstraps)"
record yes "user, second run: ok" "$(has "$out" "is installed and loaded")"
rm -f "$STUB/loaded/user_${uid}_$label"
inst --domain user --path "$tool_path"
record 2 "user, unloaded: bootstraps again" "$(bootstraps)"
printf '<!-- old -->\n' >>"$agent"
: >"$STUB/launchctl.log"
inst --domain user --path "$tool_path"
record yes "user, changed: boots out first" "$(head -n 1 "$STUB/launchctl.log" | grep -q "^bootout user/$uid/$label" && echo yes || echo no)"
record yes "user, changed: rewritten" "$(same "$agent" "$tmp/user.plist")"
record 1 "user, changed: bootstraps once" "$(bootstraps)"

# The two domains never both hold the job.
cp "$tmp/user.plist" "$tmp/keep.plist"
bash "$install" plist >"$daemon"
inst --domain user --path "$tool_path"
record 1 "user with a daemon: refused" "$?"
: >"$STUB/launchctl.log"
inst --path "$tool_path"
record 0 "system over a user agent: exit" "$?"
record no "system over a user agent: agent removed" "$([ -e "$agent" ] && echo yes || echo no)"
record yes "system over a user agent: booted out" "$(has "$STUB/launchctl.log" "bootout user/$uid/$label")"

# --- the plist ------------------------------------------------------------

reset
bash "$install" plist >"$tmp/system.plist"
record yes "plist: UserName is this user" "$(has "$tmp/system.plist" "<key>UserName</key>")"
record yes "plist: runs the job script" "$(has "$tmp/system.plist" "<string>$job</string>")"
record no "plist: launchd opens no log" "$(grep -qE 'Standard(Out|Error)Path' "$tmp/system.plist" && echo yes || echo no)"
record no "plist: no CLAUDE_CONFIG_DIR" "$(has "$tmp/system.plist" CLAUDE_CONFIG_DIR)"
record yes "plist: keeps a transient claude daemon alive" "$(has "$tmp/system.plist" "<key>AbandonProcessGroup</key>")"
# INSTALL.md's copy is this render for bot (/Users/bot, user bot, zsh).
user=$(id -un)
sed -e "s|$HOME|/Users/bot|g" -e "s|<string>$user</string>|<string>bot</string>|g" "$tmp/system.plist" >"$tmp/bot.plist"
awk '/<<.PLIST_EOF.$/ {on=1; next} /^PLIST_EOF$/ {on=0} on' "$plugin/INSTALL.md" >"$tmp/doc.plist"
record yes "INSTALL.md's plist is the render for bot" "$(same "$tmp/doc.plist" "$tmp/bot.plist")"
if command -v plutil >/dev/null 2>&1; then
	record yes "plist: plutil -lint" "$(plutil -lint -s "$tmp/system.plist" && plutil -lint -s "$tmp/user.plist" && echo yes || echo no)"
fi
HOME="$tmp/has space" bash "$install" plist >"$out" 2>&1
record 1 "plist: refuses a HOME it can't carry" "$?"

# --- status ---------------------------------------------------------------

st() { bash "$install" status >"$out" 2>&1; }
reset
st
record 1 "status, nothing installed: exit" "$?"
record yes "status, nothing installed: no launchd job" "$(has "$out" "FAIL: no launchd job")"

inst --path "$tool_path"
bash "$install" plist >"$daemon"
mkdir -p "$STUB/loaded" && touch "$STUB/loaded/system_$label"
touch "$STUB/kc" "$STUB/kc.default"
printf '%s ran check\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PR_NOTIFIER_HOME/job.last"
st
record 0 "status, installed: exit" "$?"
record yes "status, installed: ok" "$(has "$out" "status: ok")"
record yes "status, installed: loaded" "$(has "$out" "ok: system/$label is loaded: state=running runs=3 last-exit=0")"
record yes "status, installed: names the keychain" "$(has "$out" "unlocks the default keychain, $STUB/kc")"

echo 1 >"$STUB/exit"
st
record yes "status, last run failed: warns" "$(has "$out" "its last run failed")"
rm -f "$STUB/exit"

printf '%s skipped: no wake_path\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$PR_NOTIFIER_HOME/job.last"
st
record 1 "status, job skipping: exit" "$?"
record yes "status, job skipping: says why" "$(has "$out" "skipped check: ")"

printf '2026-01-01T00:00:00Z ran check\n' >"$PR_NOTIFIER_HOME/job.last"
st
record 0 "status, job stale: exit" "$?"
record yes "status, job stale: warns" "$(has "$out" "warn: the job's last run was")"

printf '# local edit\n' >>"$shim"
st
record yes "status, shim edited: warns" "$(has "$out" "warn: $shim differs")"

mkdir -p "$(dirname "$agent")" && cp "$tmp/keep.plist" "$agent"
st
record 1 "status, both domains: exit" "$?"
record yes "status, both domains: says so" "$(has "$out" "FAIL: both the LaunchDaemon")"

# --- uninstall ------------------------------------------------------------

reset
inst --path "$tool_path"
bash "$install" plist >"$daemon"
bash "$install" uninstall >"$out" 2>&1
record 1 "uninstall with a daemon: refused" "$?"
record yes "uninstall with a daemon: shim kept" "$([ -e "$shim" ] && echo yes || echo no)"
rm -f "$daemon"
inst --domain user --path "$tool_path"
bash "$install" uninstall >"$out" 2>&1
record 0 "uninstall: exit" "$?"
record no "uninstall: agent gone" "$([ -e "$agent" ] && echo yes || echo no)"
record no "uninstall: agent unloaded" "$([ -e "$STUB/loaded/user_${uid}_$label" ] && echo yes || echo no)"
record no "uninstall: job gone" "$([ -e "$job" ] && echo yes || echo no)"
record no "uninstall: shim gone" "$([ -e "$shim" ] && echo yes || echo no)"
record "$wake" "uninstall: state kept" "$(wake_path)"

# --- the job --------------------------------------------------------------

# The installed CLI, stubbed: records its arguments and environment.
fake_cli() {
	mkdir -p "$HOME/.local/bin"
	cat >"$shim" <<'CLI_EOF'
#!/bin/sh
printf 'args=%s\npath=%s\npwd=%s\ncfg=%s\n' "$*" "$PATH" "$(pwd)" "${CLAUDE_CONFIG_DIR-<unset>}" >"$STUB/cli"
CLI_EOF
	chmod +x "$shim"
}
run_job() { sh "$job_src" >"$out" 2>&1; }
config() { mkdir -p "$PR_NOTIFIER_HOME" && printf '{"wake_path": "%s"}\n' "$1" >"$PR_NOTIFIER_HOME/config.json"; }

reset
run_job
record 1 "job, no config: exit" "$?"
record yes "job, no config: says so" "$(has "$PR_NOTIFIER_HOME/job.log" "skipped: no wake_path")"
record yes "job, no config: job.last" "$(has "$PR_NOTIFIER_HOME/job.last" "skipped: no wake_path")"

reset
fake_cli
config "$wake"
touch "$STUB/kc" "$STUB/kc.default"
CLAUDE_CONFIG_DIR=$HOME/.claude-other run_job
record 0 "job: exit" "$?"
record "args=check" "job: runs check" "$(grep '^args=' "$STUB/cli")"
record "$wake" "job: PATH is wake_path" "$(sed -n 's/^path=//p' "$STUB/cli")"
record / "job: from /" "$(sed -n 's/^pwd=//p' "$STUB/cli")"
record "<unset>" "job: no CLAUDE_CONFIG_DIR" "$(sed -n 's/^cfg=//p' "$STUB/cli")"
record yes "job: unlocks the default keychain, empty password" "$(has "$STUB/security.log" "unlock-keychain -p  $STUB/kc")"
record yes "job: job.last" "$(has "$PR_NOTIFIER_HOME/job.last" "ran check")"

reset
fake_cli
config "$wake"
touch "$STUB/kc" "$STUB/kc.default"
echo 51 >"$STUB/unlock.rc"
run_job
record 1 "job, locked keychain: exit" "$?"
record no "job, locked keychain: no check" "$([ -e "$STUB/cli" ] && echo yes || echo no)"
record yes "job, locked keychain: logged" "$(has "$PR_NOTIFIER_HOME/job.log" "skipped: couldn't unlock $STUB/kc")"

reset
fake_cli
config "$wake"
touch "$STUB/kc.default" # the default names a keychain that isn't there
run_job
record 0 "job, no keychain file: runs" "$?"
record no "job, no keychain file: no unlock" "$(has "$STUB/security.log" unlock-keychain)"

reset
fake_cli
config "$wake"
run_job
record 0 "job, no default keychain: runs" "$?"

reset
config "$wake"
run_job
record 1 "job, no CLI: exit" "$?"
record yes "job, no CLI: says so" "$(has "$PR_NOTIFIER_HOME/job.log" "is missing; run the install")"

# Logs past 1 MiB rotate to .1, replacing the old copy; smaller ones stay.
reset
fake_cli
config "$wake"
head -c 1048577 /dev/zero | tr '\0' x >"$PR_NOTIFIER_HOME/notifier.log"
printf 'old\n' >"$PR_NOTIFIER_HOME/notifier.log.1"
printf 'small\n' >"$PR_NOTIFIER_HOME/job.log"
run_job
record 1048577 "rotate: notifier.log moved to .1" "$(wc -c <"$PR_NOTIFIER_HOME/notifier.log.1" | tr -d ' ')"
record no "rotate: no notifier.log until the CLI writes one" "$([ -e "$PR_NOTIFIER_HOME/notifier.log" ] && echo yes || echo no)"
record yes "rotate: small job.log stays" "$(head -n 1 "$PR_NOTIFIER_HOME/job.log" | grep -qx small && echo yes || echo no)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
