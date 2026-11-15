# What counts as a ledger entry, for every read, every resolve and the
# SessionStart hook's reaping: an object with a string kind (decision or
# need), id, text and at, and a why, ref, cwd and resolved_at that are strings
# or absent (null counts as absent). Anything else a hand edit left is
# skipped. ledger.sh and hooks/ledger-session-start.sh both read this file, so
# the two can't disagree about which lines are entries.
def is_entry: type == "object" and (.kind == "decision" or .kind == "need")
	and (.id | type) == "string" and (.text | type) == "string" and (.at | type) == "string"
	and ([.why, .ref, .cwd, .resolved_at] | all(. == null or type == "string"));
