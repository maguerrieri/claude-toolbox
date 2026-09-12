# Self-hosted implementer environment (Team account)

The runner image and hooks for the factory's optional self-hosted path: one
ephemeral container per session, a GitHub token minted per session from the
session's own JWT, and no credential in the image. Design, the broker contract,
which repositories use it, and the acceptance tests live in the design spec,
section 2d option 5 (`docs/superpowers/specs/2026-09-11-software-factory-design.md`).

- `../scripts/factory-session-wrapper` — the wrapper (copied into the image as
  `/opt/factory/factory-session-wrapper`); tests in `../scripts/tests/`.
- `hooks/checkout`, `hooks/command` — the runner's lifecycle hooks, one-line
  shims into the wrapper.
- `Dockerfile` — the runner image; provisions with `.claude/cloud-setup.sh`
  from a pinned ref at build time.
- `compose.yml` — evaluation recipe; production uses the orchestrator's
  `spawn-runner` hook (one container per session).

Build with `.github` as the context, so the image sees the wrapper and the
hooks and nothing else:

```bash
docker build -f .github/self-hosted/Dockerfile \
  --build-arg CLAUDE_CODE_VERSION=2.1.268 \
  --build-arg FACTORY_SETUP_REF=$(git rev-parse origin/main) \
  -t <registry>/factory-runner:<tag> .github
```

`FACTORY_SETUP_REF` must be a full commit SHA (the build refuses a branch or
tag), so a rebuild can only run setup code that was reviewed at that commit.
Keep the environment secret outside the repository and point
`FACTORY_ENVIRONMENT_SECRET_FILE` at it; nothing under `.github` should ever
hold it, since that directory is the image's build context.
