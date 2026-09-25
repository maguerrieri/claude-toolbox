# Sourced by scripts/record-notify.sh and hooks/role-session-start.sh: the one
# check a Notify: target must pass to be written into a role marker and to be
# re-injected from it, so the writer never records a name the hook would drop.
#
# notify_name_ok <name> succeeds when <name> is non-empty, at most 200 bytes,
# has no surrounding whitespace, and holds no control character, backtick, or
# Unicode line break (U+0085, U+2028, U+2029). The hook prints the name as one
# code span on one line, and each rule keeps it that. It runs in the C locale,
# counting and classifying bytes, so both callers agree whatever locale each
# is started under.
notify_name_ok() (
	LC_ALL=C
	case "$1" in
	'' | [[:space:]]* | *[[:space:]] | *[[:cntrl:]]* | *'`'*) exit 1 ;;
	*$'\xc2\x85'* | *$'\xe2\x80\xa8'* | *$'\xe2\x80\xa9'*) exit 1 ;;
	esac
	[ "${#1}" -le 200 ]
)
