# Is this PreToolUse payload a subagent's Bash command that writes the role
# marker? Called by role-guard.sh (with -e, and $dir set to the roles
# directory) for a call whose payload carries an agent_id.
#
# A write to the marker needs both its directory and the session id, so the
# command must name both: a session-id variable in any form ($VAR, printenv,
# os.environ[...]) and the roles directory. Then it must write something:
# output redirected anywhere but /dev/null or an fd, a command that changes
# files, or an interpreter (which can write without showing it). Requiring all
# three keeps the test off everything else a subagent runs, such as a grep
# piped to tee or a commit message that quotes the variables, and off the
# guards' reads of the marker (`head -n 1 "$roles_dir/$sid" 2>/dev/null`),
# which pass: a subagent is in its parent's session, and the parent's role is
# the one that governs it.
#
# Like role-guard-launch.jq, this is a heuristic over the command text, not a
# shell parser. A marker path carried in from an earlier call (a cd, a pasted
# literal id) or an id read through indirection passes it.

def names_id: test("CLAUDE_(?:CODE_)?SESSION_ID(?![A-Za-z0-9_])");

def names_dir: test("session-roles|CLAUDE_SESSION_ROLES_DIR") or ($dir != "" and contains($dir));

def word($w): "(?:\\A|[^\\w.-])(?:" + $w + ")(?![\\w.-])";

def writes:
  (gsub("[0-9&]*>>?[ \\t]*/dev/null"; "") | gsub("[0-9]*>&[0-9-]"; "") | test(">"))
  or test(word("rm|mv|cp|ln|tee|touch|truncate|install|dd|unlink|rsync|ditto|shred"))
  or test("\\s-delete(?![\\w-])")
  or test(word("g?sed|perl") + "(?:\\s+[^\\s|;&]+)*?\\s+(?:-[A-Za-z]*i|--in-place)")
  or test(word("python[0-9.]*|node|ruby|perl|osascript|awk|gawk"));

(.agent_id // "") != ""
and .tool_name == "Bash"
and ((.tool_input.command // "") | names_id and names_dir and writes)
