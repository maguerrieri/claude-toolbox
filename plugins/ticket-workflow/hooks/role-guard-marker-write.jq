# Is this PreToolUse payload a subagent's Bash command that writes the role
# marker? Called by role-guard.sh (with -e) for a call whose payload carries an
# agent_id and names role-marker.sh.
#
# scripts/role-marker.sh makes every marker write the docs describe, and finds
# the session id and the roles directory itself. So a write is a run of it with
# any subcommand but `show`: pin, unpin, notify, or one the text doesn't show
# (a variable, a quoted expansion). `show` passes, so a subagent still reads
# its parent's role, and so does a run with no subcommand, which writes
# nothing. A run is the script as a command word (after any VAR=value
# assignments) or as the argument of bash, sh, zsh, exec or env (after their
# options) or of source or `.`, its path quoted or not. A mention passes: in a
# quoted string (a commit message), in a heredoc body, or as another command's
# argument (a grep, a git add).
#
# A heuristic over the command text, not a shell parser, like
# role-guard-launch.jq. A run nested in another shell's string (bash -c '…'),
# behind a wrapper (nohup, xargs, timeout), or through a copy or symlink of the
# script under another name passes it. So does a write that doesn't use the
# script at all: the docs show none, so a subagent would have to improvise one
# (the PR for #203 accepted that risk rather than keep guessing at writes from
# command text, which denied harmless commands).

# A heredoc body, from the line after `<<WORD` to the line holding WORD.
def strip_heredocs: gsub("<<-?[ \\t]*['\"]?(?<w>\\w+)['\"]?[^\\n]*\\n(?:[^\\n]*\\n)*?[ \\t]*\\k<w>(?=\\n|\\z)"; "<<");

# A shell word naming the script, however it's quoted ("$R/x/role-marker.sh",
# "$R"/x/role-marker.sh, '/x/role-marker.sh'), becomes one bare word. Then a
# quoted plain word (a "pin" subcommand) loses its quotes, every other quoted
# string is emptied so nothing inside one counts, line continuations are
# joined, and redirections (2>/dev/null, <<< x) are dropped, so the word after
# the path is the subcommand.
def normalize:
  gsub("(?<![^\\s;&|(`{])(?:\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^\\s\"';&|()<>])*?(?:\"[^\"\\\\]*role-marker\\.sh\"|'[^']*role-marker\\.sh'|role-marker\\.sh)(?![\\w.-])"; "ROLE_MARKER_SH")
  | gsub("\"(?<w>[A-Za-z-]+)\"|'(?<v>[A-Za-z-]+)'"; "\(.w // .v)")
  | gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"")
  | gsub("'[^']*'"; "''")
  | gsub("\\\\\\n"; " ")
  | gsub("[0-9]*[<>]{1,3}&?[ \\t]*[^\\s;&|()<>]+"; " ");

def run_re:
  "(?:"
  + "(?:\\A|[\\s;&|(`])(?:(?:bash|sh|zsh|exec|env)\\s+(?:(?:-\\S+|[A-Za-z_]\\w*=\\S*)\\s+)*|(?:source|\\.)\\s+)"
  + "|(?:\\A|[;&|(\\n`{!]|(?<![\\w.-])(?:then|do|else)(?=\\s))\\s*(?:[A-Za-z_]\\w*=\\S*\\s+)*"
  + ")"
  + "ROLE_MARKER_SH(?![\\w.-])"
  + "(?:[ \\t]+(?<sub>[^\\s;&|()<>]+))?";

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | strip_heredocs | normalize
  | [match(run_re; "g") | .captures[] | select(.name == "sub") | .string]
  | any(.[]; . != null and . != "show"))
