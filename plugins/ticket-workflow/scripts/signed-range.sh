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
# trust doesn't pass. The header git verified must hold one SSH signature,
# and any other signature header must be SSH too, so an SSH-looking header
# git ignored (gpgsig-sha256 in a SHA-1 repo) can't stand in for the one it
# checked. Prints one line per commit that fails,
# "<sha> <code> <subject>", where <code> is git's %G? letter (N unsigned or
# unverifiable, U a key the file doesn't list, B bad, E can't check, X/Y
# expired, R revoked) or G-not-ssh, and exits 1 when any fails. Exits 0
# when every commit passes. <file> defaults to git's
# gpg.ssh.allowedSignersFile. Exits 2 on a usage or setup error: no
# allowed-signers file, a missing or empty one, one inside a checkout of
# this repo (the branch being checked could add its own key to it), a
# shallow clone, a ref that doesn't resolve, or an empty range.
#
# Why both checks: with no file configured git reads every SSH signature as
# N, and with a missing or empty one as U (checked on git 2.54), so a
# misconfigured check fails closed. Only a listed key reads G.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/signed-range.sh" …`,
# the same way as role-marker.sh. Needs git 2.36+ (worktree list -z).
set -euo pipefail

# Check the objects a push sends, never local replacements for them
# (git replace), which git log and cat-file would otherwise read.
export GIT_NO_REPLACE_OBJECTS=1

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

# A relative path resolves where it was given: --allowed-signers against the
# current directory, the config value against the worktree's top level,
# where git runs ssh-keygen.
if [ -n "$signers" ]; then
	rel_to=$PWD
else
	signers=$(git config --type=path --get gpg.ssh.allowedSignersFile || true)
	rel_to=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
[ -n "$signers" ] || fail_setup "no allowed-signers file: pass --allowed-signers <file> or set gpg.ssh.allowedSignersFile"
case $signers in /*) ;; *) signers=$rel_to/$signers ;; esac
[ -r "$signers" ] && [ -s "$signers" ] || fail_setup "allowed-signers file $signers is missing, unreadable or empty"

# The list must live outside every checkout of this repo, and so must every
# step that leads to it: a file, a symlink or a directory in a checkout is
# repo content, which the branch being checked can change to admit its own
# key (a tracked symlink retargeted to another list, say). So every hop of
# the path's symlink chain, and every directory above each hop, must
# resolve outside them all.
canon_dir() { (cd -P -- "$1" 2>/dev/null && pwd -P); }

# Fail closed: a listing that fails, or a checkout that exists but can't be
# resolved, stops the check rather than skipping that checkout.
checkouts=()
add_checkout() { # add_checkout <checkout path>
	local wt
	if wt=$(canon_dir "$1"); then
		checkouts+=("$wt")
	elif [ -e "$1" ]; then
		fail_setup "can't resolve this repo's checkout $1"
	fi # A checkout whose directory is gone (git calls it prunable) can't hold anything.
}
top=$(git rev-parse --show-toplevel 2>/dev/null) && add_checkout "$top"
listing=$(mktemp)
trap 'rm -f "$listing"' EXIT
git worktree list --porcelain -z >"$listing" || fail_setup "can't list this repo's checkouts (git worktree list -z needs git 2.36+)"
while IFS= read -r -d '' line; do
	case $line in 'worktree '*) add_checkout "${line#worktree }" ;; esac
done <"$listing"

# Resolve the path one component at a time, as the kernel does: each
# component is looked up in the physical directory reached so far, which
# must lie outside every checkout, and a symlink met on the way is replaced
# by its target's components. So no file, symlink or directory link in a
# checkout can steer the lookup, at any hop. A step out with .. moves to the
# physical parent, which a checkout can't change.
in_checkout() { # in_checkout <physical dir>
	local ck
	for ck in ${checkouts[@]+"${checkouts[@]}"}; do
		case $1 in "$ck" | "$ck"/*) return 0 ;; esac
	done
	return 1
}
todo=()
IFS=/ read -r -a todo <<<"$signers"
cur= # the physical directory reached so far; empty is /
links=0
i=0
while [ "$i" -lt "${#todo[@]}" ]; do
	comp=${todo[i]}
	i=$((i + 1))
	case $comp in
	'' | .) continue ;;
	..) cur=${cur%/*}; continue ;;
	esac
	in_checkout "${cur:-/}" && fail_setup "allowed-signers file $signers is reached through this repo's checkout ${cur:-/}, where the branch being checked can change it; keep the list and its path outside the repo"
	if [ -L "$cur/$comp" ]; then
		links=$((links + 1))
		[ "$links" -le 40 ] || fail_setup "too many symlinks on the way to $signers"
		target=$(readlink "$cur/$comp")
		tcomps=()
		IFS=/ read -r -a tcomps <<<"$target"
		case $target in /*) cur= ;; esac
		todo=(${tcomps[@]+"${tcomps[@]}"} "${todo[@]:i}")
		i=0
	else
		cur=$cur/$comp
	fi
done

# git verifies the signature header of the repo's own hash: gpgsig in a
# SHA-1 repo, gpgsig-sha256 in a SHA-256 one.
case $(git rev-parse --show-object-format) in
sha1) native=gpgsig ;;
sha256) native=gpgsig-sha256 ;;
*) fail_setup "unknown object format" ;;
esac

ssh_signed() { # ssh_signed <sha>: the header git verified is one SSH signature, and every other is SSH too
	local obj line count=0
	obj=$(git cat-file commit "$1") || return 1
	# The headers end at the first blank line. A signature's continuation
	# lines start with a space, so only a header's own first line matches.
	while IFS= read -r line; do
		case $line in
		'gpgsig '* | 'gpgsig-sha256 '*)
			[ "${line#* }" = '-----BEGIN SSH SIGNATURE-----' ] || return 1
			[ "${line%% *}" = "$native" ] && count=$((count + 1))
			;;
		esac
	done <<<"${obj%%$'\n\n'*}"
	[ "$count" -eq 1 ]
}

# A shallow history hides the ancestors past its boundary from the walk
# below, while a push still lands them, so check only a full history.
[ "$(git rev-parse --is-shallow-repository)" = false ] ||
	fail_setup "this clone is shallow, so the range may hide commits the push would land; run git fetch --unshallow first"

base_sha=$(git rev-parse --verify -q "$base^{commit}") || fail_setup "$base is not a commit"
head_sha=$(git rev-parse --verify -q "$head^{commit}") || fail_setup "$head is not a commit"

log=$(git -c gpg.ssh.allowedSignersFile="$signers" log --no-show-signature --format='%H %G? %s' "$base_sha..$head_sha") ||
	fail_setup "git log $base..$head failed"
[ -n "$log" ] || fail_setup "no commits in $base..$head"

total=0
bad=0
while IFS=' ' read -r sha code subject; do
	total=$((total + 1))
	if [ "$code" = G ]; then
		ssh_signed "$sha" && continue
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
