# Is this PreToolUse payload a subagent's Bash command that writes the role
# marker? Called by role-guard.sh (with -e) for a call whose payload carries an
# agent_id and names role-marker.sh.
#
# scripts/role-marker.sh makes every marker write the docs describe, and finds
# the session id and the roles directory itself. So the rule is an allow-list:
# the script's path followed by any word but `show` is a write. `show` passes,
# so a subagent still reads its parent's role, and so does a path with no word
# after it, or one followed by a path or an option (a word holding / or ., or
# starting with - or +: git add …/role-marker.sh tests/x.sh, grep -c x
# …/role-marker.sh other.sh, find -name role-marker.sh -print). A word whose
# text doesn't show (a variable, a substitution, a brace or glob expansion, a
# quoted string) counts as a write, and so would a writing subcommand added to
# the script later. A variable or a for-loop name set to the path
# (S=…/role-marker.sh; bash "$S" pin) is read as the path.
#
# Where the path sits in the command doesn't matter: a command word, an `if`
# condition, a `case` branch, an argument to bash, env, nohup, sudo or any
# other wrapper all count the same. Trying to tell a command position from an
# argument position kept missing ways to reach one, so the rule doesn't try.
# Nor does it list the writing subcommands: a deny-list kept missing ways to
# hide one ({pin,}, &>/dev/null pin). What passes is a path inside a quoted
# string (a commit message, an echo) or a heredoc body, and a path followed
# by nothing, a path, or an option.
#
# A heuristic over the command text, not a shell parser, like
# role-guard-launch.jq. A run inside another shell's quoted string
# (bash -c '…'), one whose subcommand arrives on stdin (… | xargs …), one
# whose path is spelled with escapes (role\-marker.sh) or reached through
# indirection the text doesn't show, and one through a copy or symlink of the
# script under another name pass it: they take intent, and this is a drift
# backstop for a subagent following the docs, not a lock. So does a write
# that doesn't use the script at all: the docs show none, so a subagent would
# have to improvise one (#203 accepted that risk rather than keep guessing at
# writes from command text, which denied harmless commands). The other way,
# the path and a plain word that are only data to another command (bash -c
# 'cmd' …/role-marker.sh unpin, where the path is just $0; cp
# …/role-marker.sh backup) are denied.

# A heredoc: the `<<WORD` operator and its body, from the next line to the line
# holding WORD. The rest of the operator's own line stays, since more of the
# command can follow it there (… <<EOF unpin). The delimiter may hold - and .
# (<<'END-MSG').
def strip_heredocs: gsub("<<-?[ \\t]*['\"]?(?<w>[\\w.-]+)['\"]?(?<rest>[^\\n]*)\\n(?:[^\\n]*\\n)*?[ \\t]*\\k<w>(?=\\n|\\z)"; " \(.rest)");

# The names a command sets to the script's path: an assignment whose value
# names it (S=…/role-marker.sh, S="$R/…/role-marker.sh",
# p=$(ls …/role-marker.sh | tail -1)), or a for loop over it.
def path_vars:
  [ (match("(?<![\\w$])(?<n>[A-Za-z_]\\w*)=(?:[^\\s;&|]*?role-marker\\.sh|\"[^\"]*role-marker\\.sh|'[^']*role-marker\\.sh|\\$\\([^)]*role-marker\\.sh)"; "g") | .captures[0].string),
    (match("(?<![\\w$])for[ \\t]+(?<n>[A-Za-z_]\\w*)[ \\t]+in[ \\t][^;\\n]*role-marker\\.sh"; "g") | .captures[0].string) ]
  | unique;

# Each use of such a name ("$S", $S, and any braced expansion of it: ${S},
# "${S:-}", ${S%x}) is spelled as the path. The braced form needs `}` or an
# expansion operator right after the name, so ${SX} isn't read as S. A name is
# word characters only, so it is safe inside the pattern.
def expand_path_vars:
  . as $cmd
  | reduce ($cmd | path_vars[]) as $n ($cmd;
      ("(?:" + $n + "(?!\\w)|\\{" + $n + "(?:[:\\-=?+#%/^,@\\[][^}]*)?\\})") as $use
      | gsub("\"\\$" + $use + "\""; " role-marker.sh")
      | gsub("\\$" + $use; "role-marker.sh"));

# A shell word naming the script, however it's quoted ("$R/x/role-marker.sh",
# "$R"/x/role-marker.sh, '/x/role-marker.sh'), becomes one bare word. Then a
# quoted plain word (a "pin" subcommand) loses its quotes, even inside a word
# ("un"pin, un'p'in); a quoted path stays path-like; every other quoted string
# is emptied, so nothing inside one counts; line continuations are joined; an
# unquoted backslash escape loses its backslash (un\pin), as the shell reads
# them; a process substitution becomes a /dev/fd path, as the command sees it;
# and redirections (2>/dev/null, &>>log, >|out, <<< x, < <(…)) are dropped, so
# the word after the path is the subcommand.
def normalize:
  gsub("(?<![^\\s;&|()`{])(?:\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^\\s\"';&|()<>])*?(?:\"[^\"\\\\]*role-marker\\.sh\"|'[^']*role-marker\\.sh'|role-marker\\.sh)(?![\\w.-])"; "ROLE_MARKER_SH")
  | gsub("\"(?<w>[A-Za-z-]+)\"|'(?<v>[A-Za-z-]+)'"; "\(.w // .v)")
  | gsub("\"[^\"$`\\\\]*[/.][^\"$`\\\\]*\"|'[^']*[/.][^']*'"; "QUOTED/PATH")
  | gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"")
  | gsub("'[^']*'"; "''")
  | gsub("\\\\\\n"; " ")
  | gsub("\\\\(?<c>[^\\n])"; "\(.c)")
  | gsub("[<>]\\([^()]*\\)"; "/dev/fd/PROCSUB")
  | gsub("(?:[0-9]+|&)?(?:>\\||[<>]{1,3})&?[ \\t]*[^\\s;&|()<>]+"; " ");

# The path, then a word that isn't `show`: one whose text doesn't show (it holds
# a $, a backtick or an emptied quoted string), or any plain word that isn't a
# path or an option.
def write_re:
  "ROLE_MARKER_SH(?![\\w.-])[ \\t]+(?!show(?![^\\s;&|()<>]))"
  + "(?:[^\\s;&|()<>]*(?:[$`]|\"\"|'')|(?![-+])[^\\s;&|()<>/.]+(?![^\\s;&|()<>]))";

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | strip_heredocs | expand_path_vars | normalize | test(write_re))
