# Invisible characters stay escaped

Some files here name zero-width, bidi and tag characters as `\uXXXX` escapes
or byte patterns, never as the characters themselves, which no editor shows
and a tool can silently strip: the ledger's filters
(`plugins/ledger/scripts/show.jq`, the checks in `ledger.sh`), for one.

Claude Code's Write and Edit tools decode a backslash-u escape typed in their
text into the literal character. On #320, retyping `show.jq`'s filter turned
its escape for the right-to-left override, U+202E, into the character itself,
and so did a first draft of this note and a test fixture.

- To move a line that holds such escapes, copy it with a shell tool (`grep`,
  `awk`, `perl`) rather than retyping it. To write one, spell the backslash
  some other way (`perl`'s `\x5c`, `printf '\134'`).
- In prose, name the code point (U+202E) instead of writing the escape.
- Then check the file's bytes. `LC_ALL=C grep -c '[^ -~<tab>]' <file>`, with
  a real tab, prints 0 for plain ASCII;
  `plugins/ledger/tests/test-ledger-hooks.sh` checks `show.jq` this way.
