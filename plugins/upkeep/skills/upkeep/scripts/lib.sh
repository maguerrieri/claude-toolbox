# lib.sh: helpers the upkeep survey scripts share. Source it; don't run it.
#
# Written for macOS /bin/bash 3.2 (the repo's AGENTS.md): no associative
# arrays, and no "${arr[@]}" on an array that can be empty under set -u.
# Every script here only reads. None of them writes to the repo, GitHub or
# the working tree, so a survey can run in any checkout.

# Byte order, so every sort comes out the same on every machine.
export LC_ALL=C

upkeep_die() { # upkeep_die <message>: report a usage or setup error, exit 2
	printf 'upkeep: %s\n' "$*" >&2
	exit 2
}

upkeep_need() { # upkeep_need <tool>...: exit 2 naming the first one missing
	for upkeep_tool in "$@"; do
		command -v "$upkeep_tool" >/dev/null 2>&1 || upkeep_die "needs $upkeep_tool on PATH"
	done
}

upkeep_days_ok() { # upkeep_days_ok <value>: a whole number of days, 1 or more
	case "$1" in '' | *[!0-9]* | 0*) return 1 ;; esac
	return 0
}

# upkeep_repo [<owner/repo>]: print the GitHub repo the survey reads, the
# argument when given, else the one gh picks for the current directory.
upkeep_repo() {
	if [ -n "${1:-}" ]; then
		case "$1" in
		*/*/* | /* | */ | *[!A-Za-z0-9_./-]*) upkeep_die "not an owner/repo: $1" ;;
		*/*) printf '%s\n' "$1" ;;
		*) upkeep_die "not an owner/repo: $1" ;;
		esac
		return
	fi
	gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null ||
		upkeep_die "can't tell which GitHub repo this is; pass --repo <owner/repo>"
}

upkeep_default_branch() { # upkeep_default_branch <owner/repo>
	gh repo view "$1" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null ||
		upkeep_die "can't read $1's default branch"
}

# upkeep_since <days>: the window's start, as an ISO-8601 UTC timestamp.
# UPKEEP_NOW (epoch seconds) stands in for the clock, for tests.
upkeep_since() {
	jq -nr --argjson d "$1" --arg n "${UPKEEP_NOW:-}" '((if $n == "" then now else ($n | tonumber) end) - $d * 86400) | floor | todate'
}

upkeep_section() { # upkeep_section <name> <tab-separated header>
	printf '## %s\n%s\n' "$1" "$2"
}

upkeep_skip() { # upkeep_skip <name> <reason>: a section that couldn't run
	printf '## %s\nskipped: %s\n' "$1" "$2"
}

# upkeep_main_checkout: the repo's main working tree (the first entry
# `git worktree list` prints), from any of its worktrees.
upkeep_main_checkout() {
	git worktree list --porcelain 2>/dev/null | awk 'NR == 1 && /^worktree / { print substr($0, 10); exit }'
}
