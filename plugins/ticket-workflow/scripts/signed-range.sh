#!/usr/bin/env bash
# signed-range.sh — check that every commit a signed fast-forward merge is
# about to land carries an SSH signature from an allowed key, for FINISH
# Step 2 in skills/ticket-workflow/phases/finish.md.
#
#   signed-range.sh [--allowed-signers <file>] <base> <head>
#
# Checks every commit in <base>..<head>, merges included. A commit passes
# only when git reads its signature as good from a key the file lists
# (%G? = G) and the signature is an SSH one: an allowed-signers file lists
# SSH keys, so an OpenPGP or X.509 signature that a local keyring happens to
# trust doesn't pass. Prints one line per commit that fails,
# "<sha> <code> <subject>", where <code> is git's %G? letter (N unsigned or
# unverifiable, U a key the file doesn't list, B bad, E can't check, X/Y
# expired, R revoked) or G-not-ssh, and exits 1 when any fails. Exits 0
# when every commit passes. <file> defaults to git's
# gpg.ssh.allowedSignersFile. Exits 2 on a usage or setup error: no
# allowed-signers file, a missing or empty one, a ref that doesn't resolve,
# or an empty range.
#
# Why both checks: with no file configured git reads every SSH signature as
# N, and with a missing or empty one as U (checked on git 2.54), so a
# misconfigured check fails closed. Only a listed key reads G.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/signed-range.sh" …`,
# the same way as role-marker.sh.
set -euo pipefail

usage() {
	echo "usage: signed-range.sh [--allowed-signers <file>] <base> <head>" >&2
	exit 2
}

fail_setup() {
	echo "signed-range.sh: $*" >&2
	exit 2
}

signers=
while [ $# -gt 0 ]; do
	case $1 in
	--allowed-signers) [ $# -ge 2 ] || usage; signers=$2; shift 2 ;;
	--) shift; break ;;
	-*) usage ;;
	*) break ;;
	esac
done
[ $# -eq 2 ] || usage
base=$1
head=$2

[ -n "$signers" ] || signers=$(git config --type=path --get gpg.ssh.allowedSignersFile || true)
[ -n "$signers" ] || fail_setup "no allowed-signers file: pass --allowed-signers <file> or set gpg.ssh.allowedSignersFile"
case $signers in /*) ;; *) signers=$PWD/$signers ;; esac
[ -r "$signers" ] && [ -s "$signers" ] || fail_setup "allowed-signers file $signers is missing, unreadable or empty"

base_sha=$(git rev-parse --verify -q "$base^{commit}") || fail_setup "$base is not a commit"
head_sha=$(git rev-parse --verify -q "$head^{commit}") || fail_setup "$head is not a commit"

log=$(git -c gpg.ssh.allowedSignersFile="$signers" log --format='%H %G? %s' "$base_sha..$head_sha") ||
	fail_setup "git log $base..$head failed"
[ -n "$log" ] || fail_setup "no commits in $base..$head"

total=0
bad=0
while IFS=' ' read -r sha code subject; do
	total=$((total + 1))
	if [ "$code" = G ]; then
		# The headers end at the first blank line; a signature's continuation
		# lines start with a space, so only the commit's own gpgsig header
		# can match at the start of a line.
		obj=$(git cat-file commit "$sha")
		case $'\n'"${obj%%$'\n\n'*}"$'\n' in
		*$'\ngpgsig -----BEGIN SSH SIGNATURE-----\n'* | *$'\ngpgsig-sha256 -----BEGIN SSH SIGNATURE-----\n'*) continue ;;
		esac
		code=G-not-ssh
	fi
	bad=$((bad + 1))
	printf '%s %s %s\n' "$sha" "$code" "$subject"
done <<<"$log"

if [ "$bad" -gt 0 ]; then
	echo "signed-range.sh: $bad of $total commits in $base..$head are not signed by a key in $signers" >&2
	exit 1
fi
echo "signed-range.sh: all $total commits in $base..$head are signed by a key in $signers" >&2
