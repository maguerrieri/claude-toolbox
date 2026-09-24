# Is this PreToolUse payload an issue-spawning launch? Called by role-guard.sh
# (with -e) for a pinned implementer's Bash and create_session calls.
#
# An issue spawn is a session whose prompt *leads* with an issue-spawning
# command: /start-ticket, /start-epic, /spawn-tickets, /spawn-epic (or their
# /ticket-workflow: forms), or /make-ticket with a --spawn or --start routing
# flag. A helper session's prompt leads with its task, so it passes.
#
# For Bash this is a small tokenizer, not a shell parser. Comments, quoted
# strings, and heredoc bodies are single tokens, so a command that is only
# mentioned in a message (a commit message, a PR body, a helper's prompt) or a
# comment never counts. The test finds a bare `claude` word run with --bg or
# -p, takes its prompt (the first positional argument, skipping each option's
# value as `claude --help` defines them), and follows a "$var" prompt to the
# last value the command gave it.

def spawn_lead: "\\A\\s*/(?:ticket-workflow:)?(?:start-ticket|start-epic|spawn-tickets|spawn-epic)(?![\\w-])";
# /make-ticket's routing flag sits right after the command or at the end.
def make_route: "\\A\\s*/(?:ticket-workflow:)?make-ticket(?:\\s+--(?:spawn|start)(?![\\w-])|(?![\\w-])[\\s\\S]*\\s--(?:spawn|start)\\s*\\z)";
def leads: test(spawn_lead) or test(make_route);

# The body of a heredoc token (<<'EOF' ... EOF) or of a heredoc command
# substitution ($(cat <<'EOF' ... EOF)).
def heredoc_body:
  sub("\\A(?:\\$\\(cat[ \\t]*)?<<[^\\n]*\\n"; "")
  | sub("(?:\\A|\\n)[ \\t]*\\w+[ \\t]*(?:\\n[ \\t]*\\))?\\s*\\z"; "");

# A word's text: one layer of quoting removed, and a heredoc command
# substitution replaced by its body.
def text:
  (if test("\\A\"[\\s\\S]*\"\\z") then .[1:-1] | gsub("\\\\(?<c>[\"\\\\$`])"; .c)
   elif test("\\A\\$?'[\\s\\S]*'\\z") then sub("\\A\\$?'"; "") | .[:-1]
   else . end)
  | if test("\\A\\$\\(cat[ \\t]*<<") then heredoc_body else . end;

def heredoc_re($n):
  "<<-?[ \\t]*(?:'(?<q\($n)>\\w+)'|\"(?<d\($n)>\\w+)\"|\\\\?(?<b\($n)>\\w+))[^\\n]*\\n(?:[\\s\\S]*?\\n)?[ \\t]*(?:\\k<q\($n)>|\\k<d\($n)>|\\k<b\($n)>)";

# A comment, a heredoc (operator through closing delimiter), a separator, or a
# word: a run of heredoc command substitutions, unquoted chunks, quoted
# strings, and backslash escapes.
def token_re:
  "#[^\\n]*"
  + "|" + heredoc_re("") + "(?=[ \\t]*(?:\\n|\\z))"
  + "|&&|\\|\\||[;&|\\n()`]"
  + "|(?:\"?\\$\\(cat[ \\t]*" + heredoc_re("s") + "[ \\t]*\\n[ \\t]*\\)\"?"
  + "|[^\\s\"'`;&|()<>\\\\]+|\"(?:[^\"\\\\]|\\\\[\\s\\S])*\"|'[^']*'|\\\\[\\s\\S])+";

def is_sep: test("\\A(?:&&|\\|\\||[;&|\\n()`])\\z");
def is_claude: test("\\A\"?(?:[^\\s\"']*/)?claude\"?\\z");
def is_launch_flag: . == "--bg" or . == "--background" or . == "-p" or . == "--print";

# claude options that take a value, per `claude --help`: required, optional
# (taken when the next word isn't an option), and variadic (every following
# word that isn't an option). Anything else is a boolean flag.
def required_value_flags: ["--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--debug-file", "--effort", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd", "--model", "-n", "--name", "--output-format", "--permission-mode", "--permission-prompts", "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings", "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot"];
def optional_value_flags: ["-d", "--debug", "--cloud", "--from-pr", "--prompt-suggestions", "--remote-control", "-r", "--resume", "--teleport", "-w", "--worktree"];
def variadic_flags: ["--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools", "--disallowed-tools", "--file", "--mcp-config", "--tools"];

# The first positional argument of a claude invocation's argument words.
def prompt_word:
  def go($k; $mode):
    if $k >= length then empty
    else .[$k] as $w
      | if $mode == "rest" then $w
        elif $mode == "value" then go($k + 1; "")
        elif ($mode == "optional" or $mode == "variadic") and ($w | startswith("-") | not)
          then go($k + 1; if $mode == "variadic" then "variadic" else "" end)
        elif $w == "--" then go($k + 1; "rest")
        elif $w | startswith("-") then
          if $w | contains("=") then go($k + 1; "")
          elif any(required_value_flags[]; . == $w) then go($k + 1; "value")
          elif any(optional_value_flags[]; . == $w) then go($k + 1; "optional")
          elif any(variadic_flags[]; . == $w) then go($k + 1; "variadic")
          else go($k + 1; "")
          end
        else $w
        end
    end;
  first(go(0; ""));

# Where the simple command holding token $j starts.
def command_start($tokens; $j):
  ([ range(0; $j) | select($tokens[.] | is_sep) ] | last // -1) + 1;

# The last value the command gives variable $v before token $i: an assignment
# (v=..., including v="$(cat <<'EOF' ...") or a heredoc read into it.
def var_value($tokens; $i; $v):
  [ range(0; $i) as $j
    | $tokens[$j] as $t
    | if $t | startswith($v + "=") then $t[($v | length) + 1:] | text
      elif ($t | startswith("<<")) and $j > 0 and $tokens[$j - 1] == $v
        and any($tokens[command_start($tokens; $j):$j][]; . == "read")
      then $t | heredoc_body
      else empty
      end ]
  | last;

# Does the claude word at token $i launch a session whose prompt leads with an
# issue spawn?
def launch_spawns($tokens; $i):
  ($tokens[$i + 1:]) as $rest
  | ([ $rest | to_entries[] | select(.value | is_sep) | .key ] | first // ($rest | length)) as $end
  | $rest[:$end] as $args
  | if any($args[]; is_launch_flag) | not then false
    else
      ([ $args | prompt_word ] | first) as $p
      | if $p == null then false
        elif $p | text | leads then true
        else
          ([ $p | capture("\\A\"?\\$\\{?(?<v>\\w+)\\}?\"?\\z") | .v ] | first) as $v
          | if $v == null then false
            else (var_value($tokens; $i; $v) // "") | leads
            end
        end
    end;

def bash_spawns:
  [ (.tool_input.command // "") | match(token_re; "g") | .string
    | select(startswith("#") | not) | gsub("\\\\\\n"; "") | select(. != "") ] as $tokens
  | any(range(0; $tokens | length); . as $i | ($tokens[$i] | is_claude) and launch_spawns($tokens; $i));

if .tool_name == "Bash" then bash_spawns
else (.tool_input.prompt // "") | leads
end
