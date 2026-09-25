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
