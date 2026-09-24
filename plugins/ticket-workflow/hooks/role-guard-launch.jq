# Is this PreToolUse payload an issue-spawning launch? Called by role-guard.sh
# (with -e) for a pinned implementer's Bash and create_session calls.
#
# An issue spawn is a session whose prompt *leads* with an issue-spawning
# command: /start-ticket, /start-epic, /spawn-tickets, /spawn-epic (or their
# /ticket-workflow: forms), or /make-ticket with --spawn or --start. A helper
# session's prompt leads with its task, so it passes.
#
# For Bash this is a small tokenizer, not a shell parser. Quoted strings and
# heredoc bodies are single tokens, so a command that is only mentioned inside
# a message (a commit message, a PR body, a helper's prompt) never counts: the
# test looks at the arguments of a bare `claude` word that also has `--bg`.

def spawn_lead: "\\A\\s*/(?:ticket-workflow:)?(?:start-ticket|start-epic|spawn-tickets|spawn-epic)(?![\\w-])";
def make_lead: "\\A\\s*/(?:ticket-workflow:)?make-ticket(?![\\w-])";
def route_flag: "(?:\\A|\\s)--(?:spawn|start)(?![\\w-])";

# Does prompt text (from its first character on) lead with an issue spawn?
def leads: test(spawn_lead) or (test(make_lead) and test(route_flag));

# A heredoc (operator through closing delimiter), a separator, or a word: a
# run of unquoted chunks, quoted strings, and backslash escapes.
def token_re:
  "<<-?[ \\t]*(?:'(?<q>\\w+)'|\"(?<d>\\w+)\"|\\\\?(?<b>\\w+))[^\\n]*\\n(?:[\\s\\S]*?\\n)?[ \\t]*(?:\\k<q>|\\k<d>|\\k<b>)(?=[ \\t]*(?:\\n|\\z))"
  + "|&&|\\|\\||[;&|\\n()`]"
  + "|(?:[^\\s\"'`;&|()<>\\\\]+|\"(?:[^\"\\\\]|\\\\[\\s\\S])*\"|'[^']*'|\\\\[\\s\\S])+";

def is_sep: test("\\A(?:&&|\\|\\||[;&|\\n()`])\\z");
def is_claude: test("\\A(?:[^\\s\"'$]*/)?claude\\z");

# A word's text with one layer of leading quoting removed: "x", 'x', $'x'.
def unquote: sub("\\A\\$?[\"']"; "");

# The text a variable's value starts with, for each place the command sets
# it: an assignment (v=..., v="$(cat <<'EOF' ..."), or a heredoc read into it.
def var_values($cmd; $v):
  [ ($cmd | match("(?:\\A|[\\s;&|(])" + $v + "=(?:\\$?[\"'])?(?:\\$\\(cat[ \\t]*<<-?[ \\t]*['\"]?\\w+['\"]?[^\\n]*\\n)?(?<rest>[\\s\\S]*)"; "g")),
    ($cmd | match("\\bread\\b[^\\n]*[ \\t]" + $v + "[ \\t]*<<-?[ \\t]*['\"]?\\w+['\"]?[^\\n]*\\n(?<rest>[\\s\\S]*)"; "g"))
  | .captures[] | select(.name == "rest") | .string ];

# Does any argument of this claude invocation lead with an issue spawn, read
# directly or through a variable the command sets?
def spawning_args($cmd):
  . as $args
  | any(range(0; $args | length);
      . as $k
      | ($args[$k:] | map(unquote) | join(" ")) as $text
      | ([ $args[$k] | capture("\\A\"?\\$\\{?(?<v>\\w+)\\}?\"?\\z") | .v ] | first) as $v
      | ($text | leads)
        or (if $v then any(var_values($cmd; $v)[]; leads) else false end));

def bash_spawns:
  (.tool_input.command // "") as $cmd
  | [ $cmd | match(token_re; "g") | .string ] as $tokens
  | any(range(0; $tokens | length);
      . as $i
      | ($tokens[$i] | is_claude)
        and (($tokens[$i + 1:]) as $rest
             | ([ $rest | to_entries[] | select(.value | is_sep) | .key ] | first // ($rest | length)) as $end
             | $rest[:$end]
             | any(.[]; . == "--bg") and spawning_args($cmd)));

if .tool_name == "Bash" then bash_spawns
else (.tool_input.prompt // "") | leads
end
