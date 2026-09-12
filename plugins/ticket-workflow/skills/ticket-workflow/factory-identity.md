# Factory identity: the App token broker and `factory-token`

Read on demand from START Step 7 (like `trackers/`, `profiles/`, `roles/`). This
is the operator and session guide for the identity path the software-factory
design picked in section 2d, item 8b: **one org-owned GitHub App + a token broker
on Cloud Run**, gated on milestone **M1** (pass-through mode honours a
caller-supplied token; the manual runbook in spec 2d closes it).

## What a session sees

An implementer environment (`factory-implementer-<repo>`, one per factory repo,
spec 2b) carries three things and nothing else identity-related:

| Where | Value | Why |
|---|---|---|
| Environment variable `GH_TOKEN` | `factory-token-required` (a non-secret sentinel) | Puts the session in pass-through mode, where the git proxy stops substituting the user's credential (spec 2d, fact 1). The helper refuses to run under `proxy-injected`. |
| Environment variable `FACTORY_BROKER_URL` | `https://factory-token-broker-<hash>-<region>.a.run.app` | Where the helper mints from. |
| API credential (personal account only) | host = the broker's host, header `Authorization: Bearer fb_…` | The agent proxy attaches the bearer **after the request leaves the VM**; the session never holds it. The broker maps this bearer to exactly one repository. |

Team-account environments cannot carry the bearer (API credentials are Pro/Max
only, and a bearer is a write-capable credential under 2b's rule), so Team
implementers wait on M3 / item 14; org-repo implementers launch from the
personal account meanwhile.

The one write-capable credential a session ever holds is the **installation
token** the broker returns: scoped to that repository, `contents: write` +
`pull_requests: write`, at most one hour, cached in a 0600 file under the
session's runtime dir.

## Using the helper in a session

The helper is `scripts/factory-token` in this plugin; the SessionStart hook
exports `CLAUDE_TICKET_WORKFLOW_ROOT`, so:

```bash
ft="${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/factory-token"
"$ft" status                       # repo, broker, auth mode, cache state — never a token
"$ft" setup-git                    # once per checkout, before the first push (below)
"$ft" exec -- gh pr create ...     # any gh call: runs with GH_TOKEN = the App token
eval "$("$ft" env)" && gh pr view  # same, for a whole shell line
```

Each Bash tool call is a fresh shell, so `GH_TOKEN` cannot be exported once for
the session; `exec --` / `eval "$(… env)"` is the per-command form, and START
Steps 7–8 prefix every `gh` call with it. **Pushes** don't need it: `setup-git`
installs the helper as the checkout's git credential helper (after resetting
the inherited helper list, so a global helper cannot answer first), answering
only for exactly `https://github.com`, and sets `remote.origin.pushurl` to
`https://github.com/<owner>/<repo>.git` so an SSH origin cannot bypass it. So
`git push` asks the helper for github.com credentials and gets the broker's
token — the durable equivalent of `gh auth setup-git`, which would only ever
see one command's `GH_TOKEN`. It also sets `user.name` / `user.email` to
`<slug>[bot]` / `<bot-user-id>+<slug>[bot]@users.noreply.github.com` so
commits, not only the PR, carry the App identity (spec 2d, fact 5), and refuses
(exit 4) if the broker names no slug / bot user id rather than leave a
half-configured identity. START Step 5 runs it **before the first commit**;
commits made earlier keep whatever identity they had.

The helper resolves the repository from the checkout's `origin` remote (or
`--repo` / `FACTORY_REPO`), asks the broker for exactly that repository, and
refuses (exit 4, nothing cached or exported) if the answer names any other
repository or carries any permission set other than `contents: write` +
`pull_requests: write` (GitHub's implicit `metadata: read` allowed).
Exit 3 means the environment is in proxy-injected mode: the token would be
silently ignored and the PR authored as the user, so stop and report rather than
push (that is M1 failing, not a helper bug).

Coordinator and interactive sessions never call the helper; they keep the
user's identity.

## The broker

Source: `services/factory-token-broker/` in `maguerrieri/toolbox` (Node, Cloud
Run, Terraform-managed alongside the MCP services; its README is the deployment
runbook). Contract:

```
POST /token            Authorization: Bearer <bearer>     body (optional): {"repository": "owner/repo"}
  200 {"token","expires_at","expires_in","repository","permissions","app":{"slug","bot_user_id","bot_login"}}
  401 unknown or missing bearer
  403 body names a repository other than the bearer's bound one  (fail closed, no token)
GET  /healthz          200
```

The App private key lives in Secret Manager (`<service_name>-app-key`,
`factory-token-broker-app-key` by default; `terraform output -raw
app_key_secret` names it) and is read only by the broker's runtime service
account. Bearers are never stored: the bindings secret
(`<service_name>-bindings`, `terraform output -raw bindings_secret`) maps
**`sha256(bearer)`** to `{repository, label}`, so a leaked bindings file mints
nothing.

## Rotation

**A bearer** (one per implementer environment; rotate when an environment is
deleted, a bearer might have been exposed, or on a schedule):

1. Generate: `printf 'fb_%s\n' "$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"`.
2. Add its hash to the bindings secret (a new secret version; see the broker
   README for the `jq` one-liner) with the same `repository` as the old entry.
   The broker reloads bindings on its next request, so both bearers work for
   the moment.
3. On the environment page (Claude.ai › Code › environment ›
   *API credentials*), replace the bearer value for the broker host.
4. Remove the old hash from the bindings secret (another version). Old sessions
   still hold their cached hour-scoped token until it expires; nothing else is
   affected. No account, App, or key changes.

**The App private key** (rotate when it might have been exposed, or yearly):

1. GitHub › the App's settings › *Private keys* › *Generate a private key*
   (GitHub allows two at once).
2. `gcloud secrets versions add "$(terraform output -raw app_key_secret)" --data-file=<new>.pem`
   (from the broker's `terraform/`). The broker reads `latest` on each mint, so
   the next token uses the new key.
3. Delete the old key in the App settings. No environment or bearer changes.

**The App itself** is registered once under `sprue.works` (public visibility so
it installs on the personal account too; permissions Contents read & write,
Pull requests read & write, Metadata read; no webhook), installed on each
factory repo with *Only select repositories*. Adding a factory repo = install
the App on it, create its implementer environment with a fresh bearer, add
that bearer's hash to the bindings secret bound to the repo.

## Isolation test (spec 2d item 4, the 8b acceptance test)

From a session in `factory-implementer-<A>`:

```bash
"${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/factory-isolation-test" --bound OWNER/A --foreign OWNER/B
```

It tries the broker directly with `repository: B` and with no repository,
replays the helper for B, scans the environment for bearer-shaped or PEM
values, then with a normally minted A token (passed to curl through a 0600
config file, never on a command line) checks `/installation/repositories`
lists only A and that a blob write to B is rejected (a public B's metadata is
readable by anyone, so `GET /repos/B` is reported but not judged). Only an
expected refusal passes a negative path: a broker that is down or answers 5xx
is reported as inconclusive and fails, and so does a helper that stops on
proxy-injected mode (exit 3) instead of refusing the repository (exit 4).
The script exits non-zero unless every path passes.
`--skip-github` runs the broker/helper/environment paths only (what CI runs
against the fake broker in `tests/`). Record the output in the PR that enables
item 4b.
