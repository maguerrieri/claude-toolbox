#!/usr/bin/env bash
# Tests for scripts/signed-range.sh, the signature check FINISH Step 2 runs
# before a signed fast-forward merge: which commits pass, which fail and how
# they're listed, and the setup errors. Signs commits with two throwaway SSH
# keys made here, one listed in the allowed-signers file and one not, in a
# scratch repo that ignores the user's git config. Needs git 2.36+ and
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

# The same PGP commit plus an SSH-looking gpgsig-sha256 header, which a SHA-1
# repo doesn't verify: git reads it good on the PGP header alone.
both=$(g cat-file commit pgp | awk '{ print } /^ -----END PGP SIGNATURE-----$/ {
	print "gpgsig-sha256 -----BEGIN SSH SIGNATURE-----"; print " U1NIU0lH"; print " -----END SSH SIGNATURE-----" }' |
	sed 's/^pgp$/both/' | g hash-object -t commit -w --stdin)
g tag both "$both"

# A good SSH-signed commit with its gpgsig header repeated.
twice=$(g cat-file commit good | awk '
	/^gpgsig / { sig = 1 } sig && !/^gpgsig / && !/^ / { printf "%s", block; sig = 0 }
	sig { block = block $0 "\n" } { print }' | sed 's/^two$/twice/' | g hash-object -t commit -w --stdin)
g tag twice "$twice"

# A SHA-256 repo signs with gpgsig-sha256.
repo256=$tmp/repo256
git init -q -b main --object-format=sha256 "$repo256"
g256() { git -C "$repo256" "$@"; }
g256 config user.email a@x
g256 config user.name A
g256 config gpg.format ssh
g256 config user.signingkey "$tmp/allowed-key.pub"
g256 commit -q --allow-empty -m base
g256 commit -q -S --allow-empty -m one

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
record 'G' 'git reads the two-header commit good on its PGP header' "$(g log -1 --format=%G? both)"
record 'G-not-ssh:both|exit 1' 'an SSH header git did not verify does not count' "$(run --allowed-signers "$tmp/allowed_signers" good both)"
record '2' 'the repeated-header commit has two gpgsig headers' "$(g cat-file commit twice | grep -c '^gpgsig ')"
record 'exit 1' 'a repeated signature header fails' "$(run --allowed-signers "$tmp/allowed_signers" good twice | sed 's/.*|//')"
record '|exit 0' 'a SHA-256 repo checks gpgsig-sha256' \
	"$(repo=$repo256 run --allowed-signers "$tmp/allowed_signers" HEAD~1 HEAD)"

g config gpg.ssh.allowedSignersFile "$tmp/allowed_signers"
record '|exit 0' 'the file defaults to gpg.ssh.allowedSignersFile' "$(run base good)"
record 'N:unsigned|exit 1' 'the default file fails an unsigned commit' "$(run base unsigned)"
g config --unset gpg.ssh.allowedSignersFile
cp "$tmp/allowed_signers" "$tmp/rel_signers"
record '|exit 0' 'a relative path resolves from the current directory' "$(run --allowed-signers ../rel_signers base good)"

# A relative config value resolves against the top level, as git resolves it.
mkdir "$repo/sub"
g config gpg.ssh.allowedSignersFile ../rel_signers
record 'G' 'git reads a relative config path from the top level' "$(cd "$repo/sub" && git log -1 --format=%G? good)"
record 'exit 0' 'so does the script, run from a subdirectory' \
	"$(cd "$repo/sub" && bash "$script" base good 2>/dev/null; echo "exit $?")"

# A list inside any checkout of the repo is content the branch can change.
cp "$tmp/allowed_signers" "$repo/in_repo_signers"
g config gpg.ssh.allowedSignersFile in_repo_signers
record '|exit 2' 'a configured list inside the checkout' "$(run base good)"
g config --unset gpg.ssh.allowedSignersFile
record '|exit 2' 'a passed list inside the checkout' "$(run --allowed-signers "$repo/sub/../in_repo_signers" base good)"
ln -s "$repo/in_repo_signers" "$tmp/link_signers"
record '|exit 2' 'a symlink outside to a list inside the checkout' "$(run --allowed-signers "$tmp/link_signers" base good)"
ln -s "$tmp/allowed_signers" "$tmp/link_outside"
record '|exit 0' 'a symlink to a list outside the checkout' "$(run --allowed-signers "$tmp/link_outside" base good)"
# A symlink or a directory link inside the checkout, pointing outside: the
# branch can retarget either to another list.
ln -s "$tmp/allowed_signers" "$repo/tracked_link"
record '|exit 2' 'a symlink in the checkout to a list outside' "$(run --allowed-signers "$repo/tracked_link" base good)"
mkdir "$tmp/outside_dir"
cp "$tmp/allowed_signers" "$tmp/outside_dir/signers"
ln -s "$tmp/outside_dir" "$repo/dir_link"
record '|exit 2' 'a directory link in the checkout to a list outside' "$(run --allowed-signers "$repo/dir_link/signers" base good)"
ln -s "$repo/tracked_link" "$tmp/link_to_link"
record '|exit 2' 'a symlink outside to a symlink in the checkout' "$(run --allowed-signers "$tmp/link_to_link" base good)"
rm "$repo/tracked_link" "$repo/dir_link" "$tmp/link_to_link"
# A .. after a link that points into the checkout lands in the checkout,
# though a logical cd reads it as the link's own parent.
ln -s "$repo/sub" "$tmp/sub_link"
record '|exit 2' '.. after a link into the checkout' "$(run --allowed-signers "$tmp/sub_link/../in_repo_signers" base good)"
# A directory link outside whose chain passes through a link in the
# checkout and ends outside: the checkout's link can be retargeted.
mkdir "$tmp/outside_dir2"
cp "$tmp/allowed_signers" "$tmp/outside_dir2/signers"
ln -s "$tmp/outside_dir2" "$repo/hop2"
ln -s "$repo/hop2" "$tmp/hop1"
record '|exit 2' 'a chain through a link in the checkout' "$(run --allowed-signers "$tmp/hop1/signers" base good)"
record '|exit 0' 'the same list reached directly' "$(run --allowed-signers "$tmp/outside_dir2/signers" base good)"
rm "$tmp/sub_link" "$tmp/hop1" "$repo/hop2"
# On a case-insensitive volume (macOS's default) a path typed in another
# case reaches the checkout too; a case-sensitive one can't test this.
upper=$(printf '%s' "$repo" | tr '[:lower:]' '[:upper:]')
if [ -d "$upper" ]; then
	record '|exit 2' 'a list inside the checkout, typed in another case' "$(run --allowed-signers "$upper/in_repo_signers" base good)"
fi
g worktree add -q --detach "$tmp/other-checkout" good
cp "$tmp/allowed_signers" "$tmp/other-checkout/wt_signers"
record '|exit 2' 'a list inside another worktree of the repo' "$(run --allowed-signers "$tmp/other-checkout/wt_signers" base good)"
g worktree remove --force "$tmp/other-checkout"
g worktree add -q --detach "$tmp/gone-checkout" good
rm -rf "$tmp/gone-checkout"
record '|exit 0' 'a checkout whose directory is gone holds nothing' "$(run --allowed-signers "$tmp/allowed_signers" base good)"
g worktree prune

# A shallow clone whose boundary hides the unsigned commit right below a
# signed tip: the walk would see only signed commits.
tip=$(g rev-parse two-bad~1)
git clone -q --depth 1 "file://$repo" "$tmp/shallow" 2>/dev/null
git -C "$tmp/shallow" fetch -q --depth 1 origin "$(g rev-parse base)" "$tip" 2>/dev/null
record 'G' 'the shallow walk sees only the signed tip' \
	"$(git -C "$tmp/shallow" -c gpg.ssh.allowedSignersFile="$tmp/allowed_signers" log --format=%G? "$(g rev-parse base)..$tip" | paste -sd, -)"
record '|exit 2' 'a shallow clone is refused' \
	"$(repo=$tmp/shallow run --allowed-signers "$tmp/allowed_signers" "$(g rev-parse base)" "$tip")"

# A git whose worktree listing fails: the check stops rather than skip it.
mkdir "$tmp/bin"
printf '#!/bin/sh\n[ "$1" = worktree ] && exit 1\nexec %s "$@"\n' "$(command -v git)" >"$tmp/bin/git"
chmod +x "$tmp/bin/git"
record '|exit 2' 'a failed worktree listing' "$(PATH="$tmp/bin:$PATH" run --allowed-signers "$tmp/allowed_signers" base good)"

g config log.showSignature true
record '|exit 0' 'log.showSignature adds no lines' "$(run --allowed-signers "$tmp/allowed_signers" base good)"
record 'N:unsigned|exit 1' 'log.showSignature still lists the failure' "$(run --allowed-signers "$tmp/allowed_signers" base unsigned)"
g config --unset log.showSignature

# A local replacement of the unsigned commit by a signed one would make
# git log read the range as signed; the push still sends the original.
g replace unsigned good
record 'G' 'the replacement reads signed to git log' \
	"$(g -c gpg.ssh.allowedSignersFile="$tmp/allowed_signers" log --format=%G? base..unsigned | sort -u | paste -sd, -)"
record 'N:unsigned|exit 1' 'the original commit is checked, not its replacement' "$(run --allowed-signers "$tmp/allowed_signers" base unsigned)"
g replace -d "$(g rev-parse unsigned)" >/dev/null

record '|exit 2' 'no file passed or configured' "$(run base good)"
record '|exit 2' 'an empty file' "$(run --allowed-signers "$tmp/empty_signers" base good)"
record '|exit 2' 'a missing file' "$(run --allowed-signers "$tmp/nope" base good)"
record '|exit 2' 'an empty range' "$(run --allowed-signers "$tmp/allowed_signers" good good)"
record '|exit 2' 'a ref that does not resolve' "$(run --allowed-signers "$tmp/allowed_signers" base no-such-ref)"
record '|exit 2' 'one ref only' "$(run --allowed-signers "$tmp/allowed_signers" base)"
record '|exit 2' 'an unknown flag' "$(run --allow "$tmp/allowed_signers" base good)"

finish
