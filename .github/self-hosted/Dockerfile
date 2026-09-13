# Runner image for the factory's self-hosted implementer environments (spec
# section 2d option 5, work item 14). One container serves exactly one session
# (--capacity 1, --drain-grace-sec 0) and is destroyed when the runner exits.
#
# The image carries no git credentials and no App key. Every session's GitHub
# token is minted by /opt/factory/factory-session-wrapper from the session's
# own JWT (see that script's header for the broker contract and the FACTORY_*
# variables the runner must be started with).
#
# Provisioning reuses the same definitions as the Anthropic-hosted
# environments: .claude/cloud-setup.sh from a pinned ref of this repository
# (item 6). It runs at image build, never from a session's checkout, which is
# the self-hosted equivalent of 2b's protected-copy stub.
#
# Build with `.github` as the context so the image sees the wrapper and the
# hooks and nothing else:
#
#   docker build -f .github/self-hosted/Dockerfile \
#     --build-arg CLAUDE_CODE_VERSION=2.1.268 \
#     --build-arg FACTORY_SETUP_REF=<full commit SHA of the reviewed setup> \
#     -t <registry>/factory-runner:<tag> .github
FROM debian:bookworm-slim
ARG CLAUDE_CODE_VERSION
ARG FACTORY_SETUP_REF
ARG FACTORY_SETUP_REPO=https://github.com/maguerrieri/claude-toolbox

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates jq \
 && rm -rf /var/lib/apt/lists/*

# Pinned runner binary; the wrapper execs this same binary via
# CLAUDE_RUNNER_CLAUDE_BIN, so the version is set once, here.
RUN curl -fsSL "https://downloads.claude.ai/claude-code-releases/${CLAUDE_CODE_VERSION:?set with --build-arg CLAUDE_CODE_VERSION}/linux-x64/claude" \
      -o /usr/local/bin/claude && chmod +x /usr/local/bin/claude

# Non-root runner user; sessions share this uid, so nothing under /opt/factory
# is writable by it (root-owned, 0555) and the hooks directory is baked in.
RUN useradd --create-home --uid 10001 runner \
 && mkdir -p /workspace && chown runner:runner /workspace \
 && git config --system user.name "Claude" \
 && git config --system user.email "noreply@anthropic.com" \
 && git config --system --add safe.directory '*'

COPY --chmod=0555 scripts/factory-session-wrapper /opt/factory/factory-session-wrapper
COPY --chmod=0555 self-hosted/hooks/ /opt/factory/hooks/

# Same provisioning as the hosted environments, from one reviewed commit.
# provision-from-ref.sh hands item 6's script the checkout it reads its inputs
# from, with `origin/main` pinned to FACTORY_SETUP_REF (a full commit SHA, never
# a branch: a rebuild must not run setup code nobody re-reviewed), installs the
# reviewed copy root-owned at /opt/factory/cloud-setup.sh, records the SHA in
# cloud-setup.ref, and deletes the context. See that script's header for why the
# context is needed and `.github/scripts/tests/test_provision_from_ref.py` for
# the integration check.
COPY --chmod=0555 self-hosted/provision-from-ref.sh /opt/factory/provision-from-ref.sh
RUN FACTORY_SETUP_REPO="$FACTORY_SETUP_REPO" FACTORY_RUN_AS=runner \
      /opt/factory/provision-from-ref.sh "${FACTORY_SETUP_REF:?set with --build-arg FACTORY_SETUP_REF=<full commit SHA>}"

USER runner
WORKDIR /workspace
# --capacity 1 and the default --drain-grace-sec 0: one session per container.
# FACTORY_* and the environment secret (or a spawn-runner work order) come
# from the deployment, never from the image. The deployment also picks the
# repo-settings guard (`--confine-repo-settings warn|enforce`): the factory
# repos' committed settings carry permissions blocks the guard inspects, so
# confirm a session starts under `enforce` before turning it on.
ENTRYPOINT ["claude", "self-hosted-runner", \
            "--environment-secret-file", "/run/secrets/environment-secret", \
            "--base-dir", "/workspace", \
            "--capacity", "1", \
            "--hooks-dir", "/opt/factory/hooks"]
