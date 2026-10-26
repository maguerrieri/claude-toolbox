#!/usr/bin/env bash
# Tests for scripts/session-prefix.sh, which picks a spawned session's name
# prefix (the issue's project or the repo, SPAWN Step 3), and for the jq
# filters the docs use to find a stopped session by its issue ID whatever its
# prefix. Runs the docs' own snippets where it can. Needs jq.
#
#   bash plugins/ticket-workflow/tests/test-session-prefix.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
skill="$plugin/skills/ticket-workflow"
script="$plugin/scripts/session-prefix.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

# A monorepo shaped like the toolbox one: projects under services/,
# mcp-servers/ and apps/, one name in two parents, an infra/ dir with one
# project and one non-project, plus a file and a hidden dir that aren't.
root="$tmp/toolbox"
mkdir -p "$root"/services/{voter-guide,sunset,home-supplies,.cache} \
	"$root"/mcp-servers/{spotify-curator,home-supplies} "$root"/apps/curator-web \
	"$root"/infra/{firebase-shared,modules}
touch "$root/services/README.md"
projects='services/* mcp-servers/* apps/* infra/firebase-shared'

prefix() { # prefix <title> [script args...]: the prefix the script prints for toolbox
	local title=$1
	shift
	printf '%s\n' "$title" | bash "$script" toolbox "$@" 2>"$tmp/err"
}
local_prefix() { prefix "$1" --root "$root" --projects "$projects"; }

record 'voter-guide' 'a project scope (#809)' "$(local_prefix 'voter-guide: Fix the ballot page')"
record 'toolbox' 'an area scope stays the repo (#811)' "$(local_prefix 'firebase apps: Bump the SDK')"
record 'toolbox' 'ci is not a project' "$(local_prefix 'ci: Cache uv')"
record 'toolbox' 'a parent dir is not a project' "$(local_prefix 'infra: Tidy modules')"
record 'toolbox' 'nor a parent of projects' "$(local_prefix 'mcp-servers: Add one')"
record 'spotify-curator' 'a project under a second parent' "$(local_prefix 'spotify-curator: Retry')"
record 'home-supplies' 'one name under two parents' "$(local_prefix 'home-supplies: Count rolls')"
record 'firebase-shared' 'a plain-dir entry' "$(local_prefix 'firebase-shared: Rotate keys')"
record 'toolbox' 'a sibling the plain entry leaves out' "$(local_prefix 'modules: Split')"
record 'toolbox' 'a scope with more words' "$(local_prefix 'spotify-curator scripts: Lint')"
record 'toolbox' 'case must match' "$(local_prefix 'Voter-Guide: Fix')"
record 'sunset' 'surrounding whitespace is trimmed' "$(local_prefix '  sunset : Fix')"
record 'toolbox' 'no colon, no scope' "$(local_prefix 'voter-guide fix the page')"
record 'toolbox' 'a file is not a project' "$(local_prefix 'README.md: Reword')"
record 'toolbox' 'a hidden dir is not a project' "$(local_prefix '.cache: Clear')"
record 'toolbox' 'a path scope is not a project' "$(local_prefix 'services/voter-guide: Fix')"
record 'toolbox' 'a quoted scope is not a project' "$(local_prefix '`voter-guide`: Fix')"
record 'voter-guide' 'shell characters later in the title are data' "$(local_prefix 'voter-guide: Fix $HOME and `ls` and "quotes"')"
record 'toolbox' 'no --projects, the repo' "$(prefix 'voter-guide: Fix' --root "$root")"
record 'toolbox' 'an empty --projects, the repo' "$(prefix 'voter-guide: Fix' --root "$root" --projects '  ')"
record 'services' 'a bare * takes top-level dirs' "$(prefix 'services: Fix' --root "$root" --projects '*')"
record 'voter-guide' 'a malformed entry is skipped' "$(prefix 'voter-guide: Fix' --root "$root" --projects '../* services/*')"
record 'yes' 'and noted' "$(grep -q "skipping malformed entry '../\*'" "$tmp/err" && echo yes)"
record 'toolbox' 'a missing parent falls back' "$(prefix 'voter-guide: Fix' --root "$root" --projects 'nope/*')"
record 'yes' 'and is noted' "$(grep -q "can't read 'nope'" "$tmp/err" && echo yes)"
record 'toolbox' 'a missing plain dir falls back' "$(prefix 'gone: Fix' --root "$root" --projects 'infra/gone')"
record 'yes' 'and is noted' "$(grep -q "no directory 'infra/gone'" "$tmp/err" && echo yes)"
record 'voter-guide' '--root defaults to the current directory' \
	"$(cd "$root" && printf 'voter-guide: Fix\n' | bash "$script" toolbox --projects "$projects")"

status() { # status <script args...>: the exit status, reading an empty title
	bash "$script" "$@" </dev/null >/dev/null 2>&1
	echo $?
}
record '2' 'no repo is a usage error' "$(status)"
record '2' 'an unknown option is a usage error' "$(status toolbox --bogus)"
record '2' 'a malformed --repo is a usage error' "$(status toolbox --repo 'o/r; rm -rf ~')"

# --repo reads the GitHub contents API. The stub serves the same tree:
# repos/o/r/contents/<dir> prints the directory's entries, a 404 otherwise.
cat >"$tmp/gh" <<'STUB_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_ARGS"
[ "$1" = api ] || exit 1
path=${2#repos/o/r/contents}
path=${path#/}
dir="$STUB_ROOT/$path"
[ -d "$dir" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
[ -n "${STUB_FAIL:-}" ] && { echo 'gh: HTTP 403' >&2; exit 1; }
for e in "$dir"/* "$dir"/.[!.]*; do
	[ -e "$e" ] || continue
	if [ -d "$e" ]; then t=dir; else t=file; fi
	jq -cn --arg n "${e##*/}" --arg t "$t" '{name: $n, type: $t}'
done | jq -cs . >"$STUB_OUT"
jq -r "$4" "$STUB_OUT"
STUB_EOF
chmod +x "$tmp/gh"
export SESSION_PREFIX_GH="$tmp/gh" STUB_ARGS="$tmp/args" STUB_ROOT="$root" STUB_OUT="$tmp/out"
remote_prefix() { : >"$tmp/args"; prefix "$1" --repo o/r --projects "$projects"; }

record 'voter-guide' '--repo: a project scope' "$(remote_prefix 'voter-guide: Fix')"
record 'api repos/o/r/contents/services' '--repo: reads the parent dir' "$(head -1 "$tmp/args" | cut -d' ' -f1-2)"
record 'toolbox' '--repo: an area scope' "$(remote_prefix 'firebase apps: Bump')"
record 'firebase-shared' '--repo: a plain-dir entry' "$(remote_prefix 'firebase-shared: Rotate')"
record 'toolbox' '--repo: a file is not a project' "$(remote_prefix 'README.md: Reword')"
record 'toolbox' '--repo: a hidden dir is not a project' "$(remote_prefix '.cache: Clear')"
record 'services' '--repo: a bare * reads the root' "$(printf 'services: Fix\n' | bash "$script" toolbox --repo o/r --projects '*' 2>/dev/null)"
record 'toolbox' '--repo: a failed read falls back' "$(STUB_FAIL=1 remote_prefix 'voter-guide: Fix')"
record 'yes' '--repo: and is noted' "$(grep -q "can't read 'services'" "$tmp/err" && echo yes)"
record '0' '--repo: a failed read still exits 0' \
	"$(printf 'voter-guide: Fix\n' | STUB_FAIL=1 bash "$script" toolbox --repo o/r --projects "$projects" >/dev/null 2>&1; echo $?)"
: >"$tmp/args"
remote_prefix 'ci: Cache' >/dev/null
record '3' '--repo: one read per star entry, none for a plain entry that cannot match' "$(wc -l <"$tmp/args" | tr -d ' ')"

# The docs' own call, from phases/spawn.md Step 3, with its placeholders filled
# and the list item's indent taken off, as a reader copying it would.
doc_call=$(extract_block "$skill/phases/spawn.md" 'session-prefix.sh" "<repo>"' | sed 's/^  //')
run_doc_call() { # run_doc_call <title>: what the docs' snippet prints
	local filled
	filled=$(printf '%s\n' "$doc_call" | sed -e 's|"<repo>"|"toolbox"|' -e "s|<checkout>|$root|" \
		-e "s|<Session projects value>|$projects|" -e "s|^<issue title>\$|$1|")
	CLAUDE_TICKET_WORKFLOW_ROOT=$plugin bash -c "$filled" 2>/dev/null
}
record 'voter-guide' 'the docs call: a project' "$(run_doc_call 'voter-guide: Fix the ballot page')"
record 'toolbox' 'the docs call: an area' "$(run_doc_call 'firebase apps: Bump the SDK')"

# The resume lookups. A stub claude prints a listing of sessions launched from
# one dir, under old (repo) and new (project) prefixes, plus near misses.
cat >"$tmp/listing.json" <<'LISTING_EOF'
[
  {"name": "voter-guide #42: new name", "cwd": "/home/me/toolbox", "status": "done", "sessionId": "b", "startedAt": "2026-10-02T00:00:00Z"},
  {"name": "toolbox #42: old name", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "a", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "toolbox 42: bare spelling", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "c", "startedAt": "2026-10-03T00:00:00Z"},
  {"name": "toolbox #420: longer id", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "d", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "toolbox #142: longer id", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "e", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "toolbox #4: shorter id", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "f", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "toolbox #42: another clone", "cwd": "/home/me/other/toolbox", "status": "stopped", "sessionId": "g", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "toolbox #50: follow-up to #42: thing", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "h", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "no colon #42", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "i", "startedAt": "2026-10-01T00:00:00Z"},
  {"cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "j", "startedAt": "2026-10-01T00:00:00Z"},
  {"name": "voter-guide #238: epic — ballots v2", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "l", "startedAt": "2026-10-05T00:00:00Z"},
  {"name": "toolbox #238: epic — ballots", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "k", "startedAt": "2026-10-04T00:00:00Z"},
  {"name": "toolbox #238: not the coordinator", "cwd": "/home/me/toolbox", "status": "stopped", "sessionId": "m", "startedAt": "2026-10-01T00:00:00Z"}
]
LISTING_EOF
mkdir "$tmp/bin"
cat >"$tmp/bin/claude" <<'STUB_EOF'
#!/usr/bin/env bash
cat "$LISTING"
STUB_EOF
chmod +x "$tmp/bin/claude"
lookup() { # lookup <file> <text>: the sessionIds the docs' block containing <text> keeps
	local block
	block=$(extract_block "$1" "$2")
	PATH="$tmp/bin:$PATH" LISTING="$tmp/listing.json" launch_dir=/home/me/toolbox \
		bash -c "$block" | jq -r 'map(.sessionId) | join(",")'
}
record 'a,b,c' 'SPAWN: an issue under either prefix and either spelling' \
	"$(lookup "$skill/phases/spawn.md" "--argjson ids '[\"#42\", \"42\"]'")"
record 'k,l' 'EPIC: a coordinator under either prefix' \
	"$(lookup "$skill/phases/epic.md" 'startswith("epic — ")')"

# Every copy of the ID filter in the docs is the same filter.
filters=$(grep -rhoE 'def issue_id: [^;]*;' "$skill" "$plugin/commands" | sort -u | wc -l | tr -d ' ')
record '1' 'one issue_id filter across the docs' "$filters"

finish
