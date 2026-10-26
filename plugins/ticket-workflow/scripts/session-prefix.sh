#!/usr/bin/env bash
# session-prefix.sh — the first word of a spawned session's name (SPAWN Step 3
# in skills/ticket-workflow/phases/spawn.md): the issue's project, or the repo.
#
#   session-prefix.sh <repo> [--projects '<entries>'] [--root <dir> | --repo <owner>/<name>] <<'TITLE_EOF'
#   <issue title>
#   TITLE_EOF
#
# <entries> is the value of the repo's `Session projects:` directive (SKILL.md
# Step 0), passed as one argument: whitespace-separated directories, each
# either `<dir>` (that one directory is a project) or `<dir>/*` (every
# directory directly inside it is one; a bare `*` means the repo root's). A
# project's name is its directory's basename.
#
# Prints the title's scope, the text before its first colon with surrounding
# whitespace trimmed, when that scope is exactly a project's name, and <repo>
# otherwise: no --projects, no scope, a scope that names no project, or a
# directory that couldn't be read. The comparison is exact, case included,
# against the names as listed, so a case-insensitive filesystem can't turn
# `Voter-Guide:` into a project. A symlinked directory is not a project, on
# either path below, so both name a session the same way.
#
# Directories are read from the checkout at --root (default: the current
# directory), or with --repo from the GitHub contents API on the default
# branch, for a spawner with no checkout of that repo. A read failure prints
# <repo> and a note on stderr, and still exits 0: a name is never worth
# failing a launch over. Malformed entries are skipped with a note.
#
# The docs run it as `bash "${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/session-prefix.sh" …`,
# the same way as role-marker.sh. SESSION_PREFIX_GH overrides the gh binary (tests).
set -euo pipefail

usage() {
	echo "usage: session-prefix.sh <repo> [--projects '<entries>'] [--root <dir> | --repo <owner>/<name>] < title" >&2
	exit 2
}

[ $# -ge 1 ] && [ -n "$1" ] || usage
fallback=$1
shift
projects=
root=.
repo=
while [ $# -gt 0 ]; do
	case $1 in
	--projects) [ $# -ge 2 ] || usage; projects=$2; shift 2 ;;
	--root) [ $# -ge 2 ] || usage; root=$2; shift 2 ;;
	--repo) [ $# -ge 2 ] || usage; repo=$2; shift 2 ;;
	*) usage ;;
	esac
done
if [ -n "$repo" ] && ! [[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
	echo "session-prefix.sh: --repo wants <owner>/<name>, got '$repo'" >&2
	exit 2
fi

title=$(cat)
scope=${title%%:*}
# Trim the scope's surrounding whitespace, then keep only a plain directory
# name: no spaces, slashes or leading dot. Anything else names no project.
scope=${scope#"${scope%%[![:space:]]*}"}
scope=${scope%"${scope##*[![:space:]]}"}
if [ -z "$projects" ] || [[ $title != *:* ]] || ! [[ $scope =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
	printf '%s\n' "$fallback"
	exit 0
fi

gh_bin=${SESSION_PREFIX_GH:-gh}

# lists <dir> ("" for the root): prints the names of the directories directly
# inside it, one a line. Fails when the directory can't be read.
lists() {
	if [ -n "$repo" ]; then
		"$gh_bin" api "repos/$repo/contents${1:+/$1}" \
			--jq 'if type == "array" then .[] | select(.type == "dir") | .name else error("not a directory") end'
	else
		[ -d "$root/$1" ] || return 1
		local d
		for d in "$root/${1:+$1/}"*/; do
			d=${d%/}
			# Skip the unmatched pattern itself, and a symlink, which the
			# contents API reports as a symlink rather than a directory.
			[ -d "$d" ] && ! [ -L "$d" ] || continue
			printf '%s\n' "${d##*/}"
		done
	fi
}

# is_dir <dir>: succeeds when <dir> is a directory, and not a symlink to one.
is_dir() {
	if [ -n "$repo" ]; then
		[ "$("$gh_bin" api "repos/$repo/contents/$1" --jq type)" = array ]
	else
		[ -d "$root/$1" ] && ! [ -L "$root/$1" ]
	fi
}

read -r -a entries <<<"$projects"
for entry in ${entries[@]+"${entries[@]}"}; do
	entry=${entry%/} # services/ and services/*/ mean services and services/*
	seg='[A-Za-z0-9_][A-Za-z0-9._-]*'
	if ! [[ $entry == '*' || $entry =~ ^($seg/)*$seg(/\*)?$ ]]; then
		echo "session-prefix.sh: skipping malformed entry '$entry'" >&2
		continue
	fi
	if [[ $entry == '*' || $entry == */\* ]]; then
		parent=${entry%\*}
		parent=${parent%/}
		if ! names=$(lists "$parent" 2>/dev/null); then
			echo "session-prefix.sh: can't read '${parent:-.}'; using '$fallback' for it" >&2
			continue
		fi
		while IFS= read -r name; do
			if [ "$name" = "$scope" ]; then
				printf '%s\n' "$scope"
				exit 0
			fi
		done <<<"$names"
	elif [ "${entry##*/}" = "$scope" ]; then
		if is_dir "$entry" 2>/dev/null; then
			printf '%s\n' "$scope"
			exit 0
		fi
		echo "session-prefix.sh: no directory '$entry'; using '$fallback' for it" >&2
	fi
done
printf '%s\n' "$fallback"
