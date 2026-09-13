#!/usr/bin/env bash
# Provision a self-hosted runner image with .claude/cloud-setup.sh taken from
# one reviewed commit (spec 2d option 5 / item 14, reusing item 6's script).
#
#   provision-from-ref.sh <full-40-hex-commit-sha>
#
# Why this is not a one-liner in the Dockerfile. item 6's script is written for
# a cloud session, so it reads its inputs from a *checkout*: `repo_dir` is
# `$CLAUDE_PROJECT_DIR` (else `$PWD`) and must contain `.git`; it runs
# `git -C "$repo_dir" fetch --depth=1 origin +refs/heads/main:refs/remotes/origin/main`
# and then reads `settings.json`, the allowlist and its own copy out of
# `origin/main`. A bare `cd /tmp && bash cloud-setup.sh` therefore dies with
# "not a git checkout" before provisioning anything.
#
# So the build hands it a checkout whose `origin/main` *is* the pinned commit:
# the commit is fetched into a fresh repository, a local `main` is pointed at
# it, and `origin` is set to that same repository over `file://`. The script's
# own fetch then succeeds with no network and resolves `origin/main` to the
# pinned SHA and nothing else — a rebuild can never pick up whatever `main` has
# become, which is the whole point of pinning. Because HEAD is checked out at
# that commit, the script's `.claude/` drift check is clean, so the snapshot is
# provisioned as a trusted one.
#
# The context is writable by the provisioning user (the script's fetch writes
# refs into it) and is deleted when this script returns; what persists in the
# image is the reviewed copy at $FACTORY_INSTALL_DIR/cloud-setup.sh (root-owned,
# 0444), the SHA in cloud-setup.ref, and whatever the script itself installed
# into the provisioning user's home.
#
# Environment (defaults suit the Dockerfile; the tests override them):
#   FACTORY_SETUP_REPO    repository to fetch the commit from
#   FACTORY_INSTALL_DIR   where the reviewed copy and the SHA record go
#   FACTORY_RUN_AS        user to provision as; empty runs as the current user
#   FACTORY_CONTEXT_DIR   context location; default a fresh mktemp -d
set -euo pipefail

repo=${FACTORY_SETUP_REPO:-https://github.com/maguerrieri/claude-toolbox}
install_dir=${FACTORY_INSTALL_DIR:-/opt/factory}
run_as=${FACTORY_RUN_AS-runner}

die() { echo "provision-from-ref: $*" >&2; exit 1; }

ref=${1:-}
case "$ref" in
  *[!0-9a-f]*|"") die "setup ref must be a full 40-hex commit SHA, got '${ref:-(empty)}'" ;;
esac
[ "${#ref}" -eq 40 ] || die "setup ref must be a full 40-hex commit SHA, got ${#ref} characters"

mkdir -p "$install_dir"
printf '%s\n' "$ref" >"$install_dir/cloud-setup.ref"
chmod 0444 "$install_dir/cloud-setup.ref"

ctx=${FACTORY_CONTEXT_DIR:-$(mktemp -d)}
cleanup() { rm -rf "$ctx"; }
trap cleanup EXIT

# A checkout of exactly $ref whose `origin` is itself, so `origin/main` is the
# pinned commit and the script's fetch needs no network.
git init -q "$ctx"
git -C "$ctx" fetch -q --depth 1 "$repo" "$ref" \
  || die "could not fetch $ref from $repo"
git -C "$ctx" checkout -q --detach FETCH_HEAD
git -C "$ctx" branch -f main FETCH_HEAD
git -C "$ctx" remote add origin "file://$ctx"
git -C "$ctx" fetch -q --depth 1 origin '+refs/heads/main:refs/remotes/origin/main'
[ "$(git -C "$ctx" rev-parse origin/main)" = "$ref" ] \
  || die "context origin/main is not $ref"

if [ ! -f "$ctx/.claude/cloud-setup.sh" ]; then
  echo "provision-from-ref: WARNING: .claude/cloud-setup.sh absent at $ref; image is NOT provisioned (item 6 pending)" >&2
  exit 0
fi

install -m 0444 "$ctx/.claude/cloud-setup.sh" "$install_dir/cloud-setup.sh"

# Run the root-owned installed copy (never the writable one in the context),
# with the context as CLAUDE_PROJECT_DIR. PATH is passed explicitly because
# `su` resets it, and the script skips the plugin install when `claude` is not
# on PATH — which would quietly leave the image unprovisioned.
if [ -n "$run_as" ] && [ "$(id -u)" = 0 ]; then
  chown -R "$run_as" "$ctx"
  home=$(getent passwd "$run_as" | cut -d: -f6)
  [ -n "$home" ] || die "no home directory for $run_as"
  su "$run_as" -c "env PATH='$PATH' HOME='$home' CLAUDE_PROJECT_DIR='$ctx' bash -euo pipefail '$install_dir/cloud-setup.sh'"
else
  CLAUDE_PROJECT_DIR="$ctx" bash -euo pipefail "$install_dir/cloud-setup.sh"
fi
