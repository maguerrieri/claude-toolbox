# Shared scaffolding for the ticket-workflow test scripts. Source it, call
# record once per case, and end the script with finish.

pass=0
fail=0

record() { # record <expected> <label> <got>
	if [ "$3" = "$1" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf 'FAIL: %s: expected %s, got %s\n' "$2" "$1" "$3"
	fi
}

finish() { # prints the tally; fails when any case failed
	printf '%d passed, %d failed\n' "$pass" "$fail"
	[ "$fail" -eq 0 ]
}

# Prints the fenced code block of <file> that contains the fixed string <text>,
# so a test runs the snippet the docs show rather than a copy of it.
extract_block() { # extract_block <file> <text>
	awk -v text="$2" '
		/^[ \t]*```/ {
			if (in_block) { if (hit) { printf "%s", buf; exit } in_block = 0; next }
			in_block = 1; buf = ""; hit = 0; next
		}
		in_block { buf = buf $0 "\n"; if (index($0, text)) hit = 1 }
	' "$1"
}
