# Is this PreToolUse payload a subagent's Bash command that writes the role
# marker? Called by role-guard.sh (with -e, and $dir set to the roles
# directory) for a call whose payload carries an agent_id.
#
# A write to the marker needs both its directory and the session id, so the
# command must name both: a session-id variable in any form ($VAR, printenv,
# os.environ[...]) and the roles directory as a path segment. Then it must
# write something: output redirected anywhere but /dev/null or an fd, a
# command that changes files, or an interpreter (which can write without
# showing it). The names are read outside single quotes, where the shell
# can't expand a variable: a quoted grep pattern only mentions them. The write
# is read outside all quotes and heredoc bodies: a `->` or `rm` in a commit
# message isn't one. Requiring all three keeps the test off what else a
# subagent runs, and off the guards' reads of the marker
# (`head -n 1 "$roles_dir/$sid" 2>/dev/null`), which pass: a subagent is in
# its parent's session, and the parent's role is the one that governs it.
#
# Like role-guard-launch.jq, this is a heuristic over the command text, not a
# shell parser. A marker path carried in from an earlier call (a cd, a pasted
# literal id) or an id read through indirection passes it; an unquoted mention
# of both names beside an unrelated write is a false hit, which the deny
# message tells the subagent how to avoid.

def names_id: test("CLAUDE_(?:CODE_)?SESSION_ID(?![A-Za-z0-9_])");

# The roles directory as a whole path segment, so session-roles.log or a
# session-roles-notes directory beside it doesn't count.
def names_dir:
  test("(?:session-roles|CLAUDE_SESSION_ROLES_DIR)(?![\\w.-])")
  or ($dir != "" and (contains($dir + "/") or contains($dir + "\"") or contains($dir + "'") or contains($dir + " ") or endswith($dir)));

def word($w): "(?:\\A|[^\\w.-])(?:" + $w + ")(?![\\w.-])";

def writes:
  (gsub("[0-9&]*>>?[ \\t]*/dev/null"; "") | gsub("[0-9]*>&[0-9-]"; "") | test(">"))
  or test(word("rm|mv|cp|ln|tee|touch|truncate|install|dd|unlink|rsync|ditto|shred|sponge|chmod|chown|chgrp|chflags|ed|ex|vi|vim|nvim"))
  or test("\\s-delete(?![\\w-])")
  or test(word("g?sed") + "(?:\\s+[^\\s|;&]+)*?\\s+(?:-[A-Za-z]*i|--in-place)")
  or test(word("python[0-9.]*|node|ruby|perl|osascript|awk|gawk"));

def interpreter: test(word("python[0-9.]*|node|ruby|perl|osascript|awk|gawk"));

# A heredoc body, from the line after `<<WORD` to the line holding WORD.
def strip_heredocs: gsub("<<-?[ \\t]*['\"]?(?<w>\\w+)['\"]?[^\\n]*\\n(?:[^\\n]*\\n)*?[ \\t]*\\k<w>(?=\\n|\\z)"; "<<");

def strip_single: gsub("'[^']*'"; "''");

def strip_double: gsub("\"(?:[^\"\\\\]|\\\\.)*\""; "\"\"");

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | strip_heredocs
  | (strip_single) as $unsingled
  | ($unsingled | strip_double) as $bare
  # An interpreter reads the environment itself, often from single-quoted
  # code, so for one the names are read in the whole command.
  | (if ($bare | interpreter) then . else $unsingled end) as $named
  | ($named | names_id) and ($named | names_dir) and ($bare | writes))
