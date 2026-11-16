# The jq helpers that every view of a ledger shares: ledger.sh's `list` and
# hooks/ledger-prompt-reminder.sh both load this file, so the two show an
# entry's characters, and order its entries, the same way.

# Control characters (C0 but tab and newline, DEL, C1) and invisible
# formatting characters (zero-width ones, bidi marks, embeddings, overrides and
# isolates, line and paragraph separators, a byte-order mark, a soft hyphen,
# the Arabic letter mark, the Mongolian vowel separator, interlinear
# annotation marks, tag characters) shown as ?. The script refuses them on a
# write; a hand-edited ledger may still hold one.
def clean: gsub("[\u0001-\u0008\u000b-\u001f\u007f-\u009f​-‏ -‮⁠-⁤⁦-⁩﻿­؜᠎￹-￻󠀀-󠁿]"; "?");

# An entry's number, for ordering two entries written in the same second.
def num: (.id[1:] | tonumber? // 0);

# An array of entries, newest first.
def newest_first: sort_by(.at, num) | reverse;
