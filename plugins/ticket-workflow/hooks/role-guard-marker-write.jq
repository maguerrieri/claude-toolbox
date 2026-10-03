# Is this PreToolUse payload a subagent's Bash command that writes the role
# marker? Called by role-guard.sh (with -e) for a call whose payload carries an
# agent_id and names role-marker.sh.
#
# scripts/role-marker.sh makes every marker write the docs describe, and finds
# the session id and the roles directory itself. So a write is the script's
# path followed by a writing subcommand: pin, unpin or notify, or one the text
# doesn't show (a variable, a substitution, a quoted expansion). `show` passes,
# so a subagent still reads its parent's role, and so does any other literal
# word (the script refuses it and writes nothing) or none.
#
# Where the path sits in the command doesn't matter: a command word, an `if`
# condition, a `case` branch, an argument to bash, env, nohup, sudo or any
# other wrapper all count the same. Trying to tell a command position from an
# argument position kept missing ways to reach one, so the rule doesn't try.
# What passes is a path inside a quoted string (a commit message, an echo) or
# a heredoc body, and a path whose next word isn't a writing subcommand
# (git add …/role-marker.sh tests/x, grep pin …/role-marker.sh).
#
# A heuristic over the command text, not a shell parser, like
# role-guard-launch.jq. A run inside another shell's quoted string
# (bash -c '…'), one whose subcommand arrives on stdin (… | xargs …), and one
# through a copy or symlink of the script under another name pass it. So does
# a write that doesn't use the script at all: the docs show none, so a
# subagent would have to improvise one (#203 accepted that risk rather than
# keep guessing at writes from command text, which denied harmless commands).
# The other way, a path and a writing subcommand that are only data to
# another command (bash -c 'cmd' …/role-marker.sh unpin, where the path is
# just $0) is denied.

# A heredoc body, from the line after `<<WORD` to the line holding WORD. The
# delimiter may hold - and . (<<'END-MSG').
def strip_heredocs: gsub("<<-?[ \\t]*['\"]?(?<w>[\\w.-]+)['\"]?[^\\n]*\\n(?:[^\\n]*\\n)*?[ \\t]*\\k<w>(?=\\n|\\z)"; "<<");

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

# The path, then a writing subcommand: pin, unpin, notify, or a word the text
# doesn't show (starting with $ or a backtick, or an emptied quoted string).
def write_re:
  "ROLE_MARKER_SH(?![\\w.-])[ \\t]+(?:(?:pin|unpin|notify)(?![\\w.-])|[$`]|\"\"|'')";

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | strip_heredocs | normalize | test(write_re))
