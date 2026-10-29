#!/usr/bin/env bash
# Tests for scripts/signed-range.sh, the signature check FINISH Step 2 runs
# before a signed fast-forward merge: which commits pass, which fail and how
# they're listed, and the setup errors. Signs commits with two throwaway SSH
# keys made here, one listed in the allowed-signers file and one not, in a
# scratch repo that ignores the user's git config. Needs git 2.34+ and
# ssh-keygen (OpenSSH 8.2+).
#
#   bash plugins/ticket-workflow/tests/test-signed-range.sh
set -u

here=$(cd "$(dirname "$0")" && pwd)
plugin=$(cd "$here/.." && pwd)
script="$plugin/scripts/signed-range.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
. "$here/lib.sh"

# Keep the user's git config and SSH agent out: signing uses the key files.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset SSH_AUTH_SOCK

ssh-keygen -q -t ed25519 -N '' -C allowed -f "$tmp/allowed-key"
ssh-keygen -q -t ed25519 -N '' -C other -f "$tmp/other-key"
printf 'a@x %s\n' "$(cut -d' ' -f1,2 "$tmp/allowed-key.pub")" >"$tmp/allowed_signers"
: >"$tmp/empty_signers"

# A stand-in gpg that calls every OpenPGP signature good and ultimately
# trusted, as a local keyring that trusts the signer would.
cat >"$tmp/fake-gpg" <<'FAKE_GPG_EOF'
#!/bin/sh
cat >/dev/null
fpr=0123456789ABCDEF0123456789ABCDEF01234567
printf '[GNUPG:] NEWSIG\n[GNUPG:] GOODSIG 0123456789ABCDEF Fake <f@x>\n'
printf '[GNUPG:] VALIDSIG %s 2026-01-01 0 4 0 22 10 00 %s\n[GNUPG:] TRUST_ULTIMATE 0 pgp\n' "$fpr" "$fpr"
FAKE_GPG_EOF
chmod +x "$tmp/fake-gpg"

repo=$tmp/repo
git init -q -b main "$repo"
g() { git -C "$repo" "$@"; }
g config user.email a@x
g config user.name A
g config gpg.format ssh
g config user.signingkey "$tmp/allowed-key.pub"
g config gpg.openpgp.program "$tmp/fake-gpg"

g commit -q --allow-empty -m base
g tag base
g commit -q -S --allow-empty -m one
g commit -q -S --allow-empty -m two
g tag good
g commit -q --allow-empty -m unsigned
g tag unsigned
g commit -q -S --allow-empty -m 'signed again'
g -c user.signingkey="$tmp/other-key.pub" commit -q -S --allow-empty -m other
g tag two-bad
g switch -q --detach good
g -c user.signingkey="$tmp/other-key.pub" commit -q -S --allow-empty -m other
g tag other
g switch -q --detach base
g commit -q -S --allow-empty -m side
g tag side
g switch -q --detach good
g merge -q --no-ff --no-edit -m merge side
g tag merge

# An OpenPGP-signed commit: the same tree and parent as good, with a PGP
# signature header the fake gpg calls good.
pgp=$(printf 'tree %s\nparent %s\nauthor A <a@x> 1700000000 +0000\ncommitter A <a@x> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEzBAABCAAdFiEE\n -----END PGP SIGNATURE-----\n\npgp\n' \
	"$(g rev-parse 'good^{tree}')" "$(g rev-parse good)" | g hash-object -t commit -w --stdin)
g tag pgp "$pgp"

run() { # run [script args...]: "<code>:<subject>,…|exit <n>" from the script's output, run in the repo
	local out code
	out=$(cd "$repo" && bash "$script" "$@" 2>/dev/null)
	code=$?
	printf '%s|exit %s' "$(printf '%s' "$out" | awk 'NF { print $2 ":" $3 }' | paste -sd, -)" "$code"
}

record '|exit 0' 'every commit signed by the allowed key' "$(run --allowed-signers "$tmp/allowed_signers" base good)"
record 'N:unsigned|exit 1' 'an unsigned commit' "$(run --allowed-signers "$tmp/allowed_signers" base unsigned)"
record 'U:other|exit 1' 'a key the file does not list' "$(run --allowed-signers "$tmp/allowed_signers" base other)"
record 'U:other,N:unsigned|exit 1' 'every failing commit, newest first' "$(run --allowed-signers "$tmp/allowed_signers" base two-bad)"
record '|exit 0' 'only the range is checked' "$(run --allowed-signers "$tmp/allowed_signers" unsigned two-bad~1)"
record 'N:merge|exit 1' 'a merge commit is checked too' "$(run --allowed-signers "$tmp/allowed_signers" base merge)"
record 'G' 'the fake gpg makes the PGP commit read good' "$(g log -1 --format=%G? pgp)"
record 'G-not-ssh:pgp|exit 1' 'a good OpenPGP signature is not an SSH one' "$(run --allowed-signers "$tmp/allowed_signers" base pgp)"

g config gpg.ssh.allowedSignersFile "$tmp/allowed_signers"
record '|exit 0' 'the file defaults to gpg.ssh.allowedSignersFile' "$(run base good)"
record 'N:unsigned|exit 1' 'the default file fails an unsigned commit' "$(run base unsigned)"
g config --unset gpg.ssh.allowedSignersFile
cp "$tmp/allowed_signers" "$tmp/rel_signers"
record '|exit 0' 'a relative path resolves from the current directory' "$(run --allowed-signers ../rel_signers base good)"

record '|exit 2' 'no file passed or configured' "$(run base good)"
record '|exit 2' 'an empty file' "$(run --allowed-signers "$tmp/empty_signers" base good)"
record '|exit 2' 'a missing file' "$(run --allowed-signers "$tmp/nope" base good)"
record '|exit 2' 'an empty range' "$(run --allowed-signers "$tmp/allowed_signers" good good)"
record '|exit 2' 'a ref that does not resolve' "$(run --allowed-signers "$tmp/allowed_signers" base no-such-ref)"
record '|exit 2' 'one ref only' "$(run --allowed-signers "$tmp/allowed_signers" base)"
record '|exit 2' 'an unknown flag' "$(run --allow "$tmp/allowed_signers" base good)"

finish
