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
# Prints the issue's project when the title's scope (the text before its first
# colon) is about exactly one, and <repo> otherwise. The scope is split into
# parts at , / + & and the word "and", and a part names a project when its
# first word is a project's name: `spotify-curator scripts` names
# spotify-curator, `voter-guide and sunset` names two, and `firebase apps`
# none. <repo> is also the answer for no --projects, no scope, or a directory
# that couldn't be read. Every entry, plain or starred, is checked
# against a listing of its parent directory, exactly and case included, so a
# case-insensitive filesystem can't turn `Voter-Guide:` into a project. A
# symlink is never a project or a parent of one, as the contents API sees it,
# so both paths below name a session the same way.
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

# A title is one line; anything after the first is not part of it.
IFS= read -r title || true
if [ -z "$projects" ] || [[ $title != *:* ]]; then
	printf '%s\n' "$fallback"
	exit 0
fi
scope=${title%%:*}

# The scope's parts, split at , / + & and the word "and", and the first word of
# each, with any punctuation around it dropped: `spotify-curator scripts` has
# one part headed spotify-curator, `voter-guide and sunset` two. Only a plain
# directory name (no spaces, slashes or leading dot) can be a project.
heads=$(printf '%s\n' "$scope" | awk '{ gsub(/[,\/+&]|[[:space:]]and[[:space:]]/, "\n"); print }' |
	while read -r word _; do
		word=${word#"${word%%[A-Za-z0-9_]*}"}
		word=${word%"${word##*[A-Za-z0-9_]}"}
		# An if, not &&: a rejected last word would end the loop, and with
		# pipefail the script, with a failing status.
		if [[ $word =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*$ ]]; then
			printf '%s\n' "$word"
		fi
	done | sort -u)
if [ -z "$heads" ]; then
	printf '%s\n' "$fallback"
	exit 0
fi
is_head() { printf '%s\n' "$heads" | grep -qxF -- "$1"; }

gh_bin=${SESSION_PREFIX_GH:-gh}

# lists <dir> ("" for the root): prints the names of the directories directly
# inside it, one a line. Fails when the directory can't be read, or when it or
# any directory on the way to it is a symlink, which the contents API reports
# as a symlink rather than a directory.
lists() {
	if [ -n "$repo" ]; then
		"$gh_bin" api "repos/$repo/contents${1:+/$1}" \
			--jq 'if type == "array" then .[] | select(.type == "dir") | .name else error("not a directory") end'
	else
		[ -d "$root/$1" ] || return 1
		local d= part
		local -a parts=()
		[ -n "$1" ] && IFS=/ read -r -a parts <<<"$1"
		for part in ${parts[@]+"${parts[@]}"}; do
			d=${d:+$d/}$part
			! [ -L "$root/$d" ] || return 1
		done
		for d in "$root/${1:+$1/}"*/; do
			d=${d%/}
			# Skip the unmatched pattern itself, and a symlink.
			[ -d "$d" ] && ! [ -L "$d" ] || continue
			printf '%s\n' "${d##*/}"
		done
	fi
}

# Collect every head that is a project's name. A directory that can't be read
# might hold another head, so the issue could be cross-cutting: use <repo>.
found=
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
	elif is_head "${entry##*/}"; then
		# A plain entry names one directory: look for it in its parent's
		# listing, as for a star entry, so the name must match exactly.
		parent=
		[[ $entry == */* ]] && parent=${entry%/*}
	else
		continue # a plain entry no head names needs no read
	fi
	if ! names=$(lists "$parent" 2>/dev/null); then
		echo "session-prefix.sh: can't read '${parent:-.}'; using '$fallback'" >&2
		printf '%s\n' "$fallback"
		exit 0
	fi
	hit=
	while IFS= read -r name; do
		if [ -n "$name" ] && is_head "$name" &&
			{ [[ $entry == '*' || $entry == */\* ]] || [ "$name" = "${entry##*/}" ]; }; then
			found=$(printf '%s\n%s\n' "$found" "$name")
			hit=1
		fi
	done <<<"$names"
	if [ -z "$hit" ] && [[ $entry != '*' && $entry != */\* ]]; then
		echo "session-prefix.sh: no directory '$entry'" >&2
	fi
done

# Exactly one project named (one name under two parents is one project) is
# the issue's project; none or several, and the issue is the repo's.
found=$(printf '%s\n' "$found" | sed '/^$/d' | sort -u)
case $(printf '%s' "$found" | grep -c '^') in
1) printf '%s\n' "$found" ;;
0) printf '%s\n' "$fallback" ;;
*)
	echo "session-prefix.sh: the scope names several projects ($(printf '%s' "$found" | paste -sd, -)); using '$fallback'" >&2
	printf '%s\n' "$fallback"
	;;
esac
