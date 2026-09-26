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
# -p and takes the words that may be its prompt: the first positional
# argument, skipping each option's value as `claude --help` defines them, and
# the word after any option that list doesn't name. It follows a "$var" in
# such a word to the last value the command gave it. With no positional
# prompt it reads stdin as far as the command text shows it: a heredoc, a
# here-string, or the words of an echo or printf piped in.

def spawn_lead: "\\A\\s*/(?:ticket-workflow:)?(?:start-ticket|start-epic|spawn-tickets|spawn-epic)(?![\\w-])";
# /make-ticket's routing flag sits right after the command, at the end of the
# command's line (directive lines can follow it), or at the end.
def make_route: "\\A\\s*/(?:ticket-workflow:)?make-ticket(?:\\s+--(?:spawn|start)(?![\\w-])|(?![\\w-])[^\\n]*\\s--(?:spawn|start)[ \\t]*(?:\\n|\\z)|(?![\\w-])[\\s\\S]*\\s--(?:spawn|start)\\s*\\z)";
def leads: test(spawn_lead) or test(make_route);

# The body of a heredoc token (<<'EOF' ... EOF) or of a heredoc command
# substitution ($(cat <<'EOF' ... EOF)).
def heredoc_body:
  sub("\\A(?:\\$\\(cat[ \\t]*)?<<[^\\n]*\\n"; "")
  | sub("(?:\\A|\\n)[ \\t]*\\w+[ \\t]*(?:\\n[ \\t]*\\))?\\s*\\z"; "");

# A word's text: a heredoc command substitution replaced by its body, or else
# the quoting removed piece by piece ("/start-ticket "$id reads as one text).
def text:
  if test("\\A\"?\\$\\(cat[ \\t]*<<") then ltrimstr("\"") | rtrimstr("\"") | heredoc_body
  else [ match("\"(?:[^\"\\\\]|\\\\[\\s\\S])*\"|\\$?'[^']*'|\\\\[\\s\\S]|[^\"'\\\\]+"; "g").string
      | if startswith("\"") then .[1:-1] | gsub("\\\\(?<c>[\"\\\\$`])"; .c)
        elif test("\\A\\$?'") then sub("\\A\\$?'"; "") | .[:-1]
        elif startswith("\\") then .[1:]
        else . end ]
    | join("")
  end;

# What a heredoc or here-string token feeds to stdin.
def stdin_text:
  if startswith("<<<") then sub("\\A<<<[ \\t]*"; "") | text else heredoc_body end;

# A heredoc, operator through closing delimiter. Group r<n> holds the rest of
# the operator's line, which is still command text (`<<'EOF' | claude -p`).
def heredoc_re($n):
  "<<-?[ \\t]*(?:'(?<q\($n)>\\w+)'|\"(?<d\($n)>\\w+)\"|\\\\?(?<b\($n)>\\w+))(?<r\($n)>[^\\n]*)\\n(?:[\\s\\S]*?\\n)?[ \\t]*(?:\\k<q\($n)>|\\k<d\($n)>|\\k<b\($n)>)";

# A redirection with its target (2>/dev/null, >>log, <in, &>out, 2>&1) or a
# here-string (<<<"text"). << is a heredoc, and <( and >( are process
# substitutions, left to the word rule.
def redirect_re:
  "(?:[0-9]+|&)?(?:<<<|>>|>\\||[<>]&|<>|>(?!\\()|<(?![<(]))[ \\t]*(?:\"(?:[^\"\\\\]|\\\\[\\s\\S])*\"|'[^']*'|[^\\s\"'`;&|()<>]+)*";

# A comment, a heredoc, a redirection, a separator, or a word: a run of
# heredoc command substitutions, unquoted chunks, quoted strings, and
# backslash escapes.
def token_re:
  "#[^\\n]*"
  + "|" + heredoc_re("") + "(?=[ \\t]*(?:\\n|\\z))"
  + "|" + redirect_re
  + "|&&|\\|\\||[;&|\\n()`]"
  + "|(?:\"?\\$\\(cat[ \\t]*" + heredoc_re("s") + "[ \\t]*\\n[ \\t]*\\)\"?"
  + "|(?:[^\\s\"'`;&|()<>\\\\$]|\\$(?!\\())+|\"(?:[^\"\\\\]|\\\\[\\s\\S])*\"|'[^']*'|\\\\[\\s\\S])+";

# The command's tokens. A heredoc token holds the rest of its operator's line,
# so that rest is tokenized again and follows it.
def tokenize:
  [ match(token_re; "g")
    | .string, ([ .captures[] | select(.name == "r" and .string != null and .string != "") | .string ] | first // empty | tokenize[]) ];

def is_sep: test("\\A(?:&&|\\|\\||[;&|\\n()`])\\z");
def is_redirect: test("\\A(?:[0-9]+|&)?[<>]");
def is_claude: test("\\A\"?(?:[^\\s\"']*/)?claude\"?\\z");
def is_launch_flag: . == "--bg" or . == "--background" or . == "-p" or . == "--print";

# claude options that take a value, per `claude --help`: required, optional
# (taken when the next word isn't an option), and variadic (every following
# word that isn't an option). Anything else is a boolean flag or an option
# `--help` doesn't list (--max-turns), so the word after it may be either a
# value or the prompt.
def required_value_flags: ["--agent", "--agents", "--append-system-prompt", "--append-system-prompt-file", "--autocompact", "--debug-file", "--effort", "--environment", "--fallback-model", "--input-format", "--json-schema", "--max-budget-usd", "--model", "-n", "--name", "--output-format", "--permission-mode", "--permission-prompts", "--plugin-dir", "--plugin-url", "--remote-control-session-name-prefix", "--session-id", "--setting-sources", "--settings", "--system-prompt", "--system-prompt-file", "--system-prompt-snapshot"];
def optional_value_flags: ["-d", "--debug", "--cloud", "--from-pr", "--prompt-suggestions", "--remote-control", "-r", "--resume", "--teleport", "-w", "--worktree"];
def variadic_flags: ["--add-dir", "--allowedTools", "--allowed-tools", "--betas", "--disallowedTools", "--disallowed-tools", "--file", "--mcp-config", "--tools"];

# The words of a claude invocation's arguments that may be its prompt: the
# first positional argument, and the word after each unlisted option.
# Redirections and stdin tokens are never the prompt.
def prompt_words:
  def go($k; $mode):
    if $k >= length then empty
    else .[$k] as $w
      | if $w | is_redirect then go($k + 1; $mode)
        elif $mode == "rest" then $w
        elif $mode == "value" then go($k + 1; "")
        elif ($mode == "optional" or $mode == "variadic") and ($w | startswith("-") | not)
          then go($k + 1; if $mode == "variadic" then "variadic" else "" end)
        elif $mode == "unlisted" and ($w | startswith("-") | not) then $w, go($k + 1; "")
        elif $w == "--" then go($k + 1; "rest")
        elif $w | startswith("-") then
          if $w | contains("=") then go($k + 1; "")
          elif any(required_value_flags[]; . == $w) then go($k + 1; "value")
          elif any(optional_value_flags[]; . == $w) then go($k + 1; "optional")
          elif any(variadic_flags[]; . == $w) then go($k + 1; "variadic")
          else go($k + 1; "unlisted")
          end
        else $w
        end
    end;
  go(0; "");

# Where the simple command holding token $j starts.
def command_start($tokens; $j):
  ([ range(0; $j) | select($tokens[.] | is_sep) ] | last // -1) + 1;

# The last value the command gives variable $v before token $i: an assignment
# (v=..., including v="$(cat <<'EOF' ...") or a heredoc or here-string read
# into it.
def var_value($tokens; $i; $v):
  [ range(0; $i) as $j
    | $tokens[$j] as $t
    | if $t | startswith($v + "=") then $t[($v | length) + 1:] | text
      elif ($t | startswith("<<")) and $j > 0 and $tokens[$j - 1] == $v
        and any($tokens[command_start($tokens; $j):$j][]; . == "read")
      then $t | stdin_text
      else empty
      end ]
  | last;

# A prompt word's text, with a leading $var or ${var} replaced by the last
# value the command gave it before token $i ("$cmd 3 5").
def prompt_text($tokens; $i):
  text as $t
  | ([ $t | capture("\\A\\$\\{?(?<v>\\w+)\\}?(?<r>[\\s\\S]*)\\z") ] | first) as $m
  | if $m == null then $t else (var_value($tokens; $i; $m.v) // "") + $m.r end;

# Does the claude word at token $i launch a session whose prompt leads with an
# issue spawn? With no positional prompt, a claude -p reads it from stdin: a
# heredoc or here-string on the command, or the words of the command piped
# into it (echo, printf, a cat of a heredoc).
def launch_spawns($tokens; $i):
  ($tokens[$i + 1:]) as $rest
  | ([ $rest | to_entries[] | select(.value | is_sep) | .key ] | first // ($rest | length)) as $end
  | $rest[:$end] as $args
  | command_start($tokens; $i) as $s
  | if any($args[]; is_launch_flag) | not then false
    else [ $args | prompt_words ] as $ps
      | any($ps[]; prompt_text($tokens; $i) | leads)
        or any($args[] | select(startswith("<<")); stdin_text | leads)
        or (($ps | length) == 0 and $s > 0 and $tokens[$s - 1] == "|"
          and any($tokens[command_start($tokens; $s - 1) + 1:$s - 1][];
            if startswith("<<") then stdin_text else prompt_text($tokens; $i) end | leads))
    end;

def bash_spawns:
  [ (.tool_input.command // "") | tokenize[]
    | select(startswith("#") | not) | gsub("\\\\\\n"; "") | select(. != "") ] as $tokens
  | any(range(0; $tokens | length); . as $i | ($tokens[$i] | is_claude) and launch_spawns($tokens; $i));

if .tool_name == "Bash" then bash_spawns
else (.tool_input.prompt // "") | leads
end
