# Is this PreToolUse payload a subagent's Bash command that writes the ledger?
# Called by ledger-guard.sh (with -e) for a call whose payload carries an
# agent_id and names ledger.sh.
#
# The same rule as ticket-workflow's hooks/role-guard-marker-write.jq, which
# has the reasoning and the cases it has been through, with the script and its
# read swapped: scripts/ledger.sh makes every ledger write the docs describe,
# so its path followed by any word but `list` is a write. `list` passes, and
# so does a path with no word after it, or one followed by a path or an option
# (a word holding / or ., or starting with - or +: git add …/ledger.sh x.sh). A
# word whose text doesn't show (a variable, a substitution, a quoted string)
# counts as a write. A path inside a quoted string (a commit message, an echo)
# or a heredoc body passes.
#
# A heuristic over the command text, not a shell parser: a run inside another
# shell's quoted string (bash -c '…'), one whose subcommand arrives on stdin,
# and one through a copy of the script under another name pass it. It is a
# drift backstop for a subagent following the docs, not a lock.

# A heredoc: the `<<WORD` operator and its body. The rest of the operator's own
# line stays, since more of the command can follow it there.
def strip_heredocs: gsub("<<-?[ \\t]*['\"]?(?<w>[\\w.-]+)['\"]?(?<rest>[^\\n]*)\\n(?:[^\\n]*\\n)*?[ \\t]*\\k<w>(?=\\n|\\z)"; " \(.rest)");

# The names a command sets to the script's path (L=…/ledger.sh, a for loop).
def path_vars:
  [ (match("(?<![\\w$])(?<n>[A-Za-z_]\\w*)=(?:[^\\s;&|]*?ledger\\.sh|\"[^\"]*ledger\\.sh|'[^']*ledger\\.sh|\\$\\([^)]*ledger\\.sh)"; "g") | .captures[0].string),
    (match("(?<![\\w$])for[ \\t]+(?<n>[A-Za-z_]\\w*)[ \\t]+in[ \\t][^;\\n]*ledger\\.sh"; "g") | .captures[0].string) ]
  | unique;

# Each use of such a name ("$L", $L, ${L}, "${L:-}") is spelled as the path.
def expand_path_vars:
  . as $cmd
  | reduce ($cmd | path_vars[]) as $n ($cmd;
      ("(?:" + $n + "(?!\\w)|\\{" + $n + "(?:[:\\-=?+#%/^,@\\[][^}]*)?\\})") as $use
      | gsub("\"\\$" + $use + "\""; " ledger.sh")
      | gsub("\\$" + $use; "ledger.sh"));

# A shell word naming the script, however it's quoted, becomes one bare word;
# a quoted plain word loses its quotes; a quoted path stays path-like; every
# other quoted string is emptied; line continuations are joined; an unquoted
# backslash escape loses its backslash; a process substitution becomes a path;
# and redirections are dropped, so the word after the path is the subcommand.
def normalize:
  gsub("(?<![^\\s;&|()`{])(?:\"(?:[^\"\\\\]|\\\\.)*\"|'[^']*'|[^\\s\"';&|()<>])*?(?:\"[^\"\\\\]*ledger\\.sh\"|'[^']*ledger\\.sh'|ledger\\.sh)(?![\\w.-])"; "LEDGER_SH")
  | gsub("\"(?<w>[A-Za-z-]+)\"|'(?<v>[A-Za-z-]+)'"; "\(.w // .v)")
  | gsub("\"[^\"$`\\\\]*[/.][^\"$`\\\\]*\"|'[^']*[/.][^']*'"; "QUOTED/PATH")
  | gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"")
  | gsub("'[^']*'"; "''")
  | gsub("\\\\\\n"; " ")
  | gsub("\\\\(?<c>[^\\n])"; "\(.c)")
  | gsub("[<>]\\([^()]*\\)"; "/dev/fd/PROCSUB")
  | gsub("(?:[0-9]+|&)?(?:>\\||[<>]{1,3})&?[ \\t]*[^\\s;&|()<>]+"; " ");

# The path, then a word that isn't `list`: one whose text doesn't show, or any
# plain word that isn't a path or an option.
def write_re:
  "LEDGER_SH(?![\\w.-])[ \\t]+(?!list(?![^\\s;&|()<>]))"
  + "(?:[^\\s;&|()<>]*(?:[$`]|\"\"|'')|(?![-+])[^\\s;&|()<>/.]+(?![^\\s;&|()<>]))";

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | strip_heredocs | expand_path_vars | normalize | test(write_re))
