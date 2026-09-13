# Factory identity: the App token broker and `factory-token`

Read on demand from START Steps 5 and 7 (like `trackers/`, `profiles/`,
`roles/`). This is the operator and session guide for the identity path the
software-factory design picked in section 2d, item 8b: **one org-owned GitHub
App + a token broker on Cloud Run**, gated on milestone **M1** (pass-through
mode honours a caller-supplied token; the manual runbook in spec 2d closes it).

## What a session sees

An implementer environment (`factory-implementer-<repo>`, one per factory repo,
spec 2b) carries three things and nothing else identity-related:

| Where | Value | Why |
|---|---|---|
| Environment variable `GH_TOKEN` | `factory-token-required` (a non-secret sentinel) | Puts the session in pass-through mode, where the git proxy stops substituting the user's credential (spec 2d, fact 1). The helper refuses to run under `proxy-injected`. |
| Environment variable `FACTORY_BROKER_URL` | `https://factory-token-broker-<hash>-<region>.a.run.app` | Where the helper mints from. Also what the SessionStart hook keys on. |
| API credential (personal account only) | host = the broker's host, header `Authorization: Bearer fb_…` | The agent proxy attaches the bearer **after the request leaves the VM**; the session never holds it. The broker maps this bearer to exactly one repository. |

Team-account environments cannot carry the bearer (API credentials are Pro/Max
only, and a bearer is a write-capable credential under 2b's rule), so Team
implementers wait on M3 / item 14; org-repo implementers launch from the
personal account meanwhile.

The one write-capable credential a session ever holds is the **installation
token** the broker returns: scoped to that repository, carrying the five
permissions 2d's least-privilege contract names, expiring within an hour, cached
in a 0600 file under the session's runtime dir.

## Using the helper in a session

**A wrapper, not an exporter.** In pass-through mode *every* `gh` call reads the
sentinel, not only the ones START Step 7 names, and an `export` in one Bash tool
call does not reach the next. So the token is supplied per process, two ways:

```bash
ft="${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/factory-token"
"$ft" status                        # repo, broker, auth mode, cache state — never a token
"$ft" setup-git                     # once, before the first commit (Step 5)
"$ft" exec -- gh pr create ...      # one command with the token in its environment
"$ft" normalize-commits <base>      # before the push (Step 7)
```

and the **`gh` shim**: the plugin's SessionStart hook runs `factory-token shim`
when `FACTORY_BROKER_URL` is set, which writes a `gh` wrapper into the cache dir
and puts it first on `PATH`, so every *other* `gh` call in the session is wrapped
too. The shim bakes the repository *and the broker* in at install time, so it
works from any directory and with neither variable exported, and it does not
recurse: inside `exec` the token is already in the environment and it runs the
real `gh` directly.

If the helper cannot install that shim, the hook installs a **deny shim**
instead — a `gh` that refuses and explains. That matters most in proxy-injected
mode: there an unwrapped `gh` does not fail on the sentinel, it quietly acts as
the *user*, so refusing is the only safe default. Do not work around a deny
shim; run `factory-token status` and fix the cause (usually M1 not being in
effect for this environment).

Step 7 still calls `exec` explicitly for the push and `gh pr create`, so identity
never depends on the hook. A branch that deletes the hook leaves those calls
wrapped anyway, and any unwrapped `gh` reads the sentinel and fails instead of
acting as the user — the fail-closed outcome 2d asks for.

**`setup-git`** (Step 5, before the first commit) runs `gh auth setup-git` under
the token, which points git's credential helper at `gh auth git-credential`: a
push under `exec` then carries the App, and an unwrapped push reads the sentinel
and fails. It also sets `remote.origin.pushurl` to
`https://github.com/<owner>/<repo>.git` so an SSH origin cannot bypass the
credential path entirely, and sets `user.name` / `user.email` to `<slug>[bot]` /
`<bot-user-id>+<slug>[bot]@users.noreply.github.com`. It refuses (exit 4, and
discards the minted token) if the broker names no App slug or bot user id, rather
than leaving half an identity wired.

**`normalize-commits <base>`** (Step 7, before the push) is what the design
actually relies on for commit attribution, because `setup-git`'s `user.email` is
only an optimization — a branch controls the SessionStart hook, so an early write
proves nothing. It inspects `origin/<base>..HEAD` (this PR's own commits, never
the base's or a stacked parent's), rewrites **author and committer** of the
commits carrying the platform's default identity `noreply@anthropic.com` to the
App's noreply address, and **stops (exit 6) on any other non-App author or
committer** rather than relabelling someone else's work. It verifies the tree is
unchanged before moving the branch. Per 2d, commit authorship is cosmetic: the
identities the factory relies on are the PR author and the pusher, both set by
the token.

`normalize-commits` walks the range in topological order, so a merge commit's
parents are rewritten before it is.

The helper resolves the repository from the checkout's `origin` remote (the exact
`github.com` host, in its three URL forms) or from `--repo` / `FACTORY_REPO`,
asks the broker for exactly that repository, and refuses (exit 4, nothing cached
or exported) if the answer names any other repository, carries anything but the
five permissions, or is already expired. Exit 3 means proxy-injected mode: the
token would be silently ignored and the PR authored as the user, so stop and
report rather than push (that is M1 failing, not a helper bug).

Coordinator and interactive sessions never call the helper; they keep the user's
identity.

## The broker

Source: `services/factory-token-broker/` in `maguerrieri/toolbox` (Node, Cloud
Run, Terraform-managed alongside the MCP services; its README is the deployment
runbook). Contract:

```
POST /token            Authorization: Bearer <bearer>     body (optional): {"repository": "owner/repo"}
  200 {"token","expires_at","expires_in","repository","permissions","app":{"slug","bot_user_id","bot_login"}}
  401 unknown or missing bearer
  403 body names a repository other than the bearer's bound one  (fail closed, no token)
  429 this bearer's daily issuance budget is spent
GET  /healthz          200
```

**Five permissions, not two.** The App token serves the whole START loop, so
2d's least-privilege contract is `contents: write`, `pull_requests: write`,
`issues: write` (the tracker's `FETCH` and the epic's `COORD` markers),
`checks: read` (`gh pr checks`), `metadata: read`. The broker requests exactly
that set and refuses a token GitHub returns with anything more, less, or
different; the helper refuses one too.

**What the hour bounds, honestly.** Each token expires an hour after issuance,
but a branch that can reach the broker through the environment's credential can
mint again for as long as the bearer is valid, so no per-session lifetime can be
claimed on a hosted environment (per-session credentials exist only in item 14's
self-hosted path). The broker enforces a per-bearer daily issuance budget
instead, and alerts on exhaustion: rate limiting and abuse detection. The blast
radius is "one repo, that permission set, non-protected branches, until the
bearer is rotated, throttled by the budget".

The App private key lives in Secret Manager (`<service_name>-app-key`,
`terraform output -raw app_key_secret` names it) and is read only by the broker's
runtime service account. Bearers are never stored: the bindings secret
(`<service_name>-bindings`, `terraform output -raw bindings_secret`) maps
**`sha256(bearer)`** to `{repository, label}`, so a leaked bindings file mints
nothing.

## Rotation

**A bearer** (one per implementer environment; rotate when an environment is
deleted, a bearer might have been exposed, or on a schedule):

1. Generate: `printf 'fb_%s\n' "$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"`.
2. Add its hash to the bindings secret (a new secret version; see the broker
   README for the guarded `jq` sequence) with the same `repository` as the old
   entry. Instances cache bindings for 60s, so wait at least 90s; from then on
   both bearers work.
3. On the environment page (Claude.ai › Code › environment › *API credentials*),
   replace the bearer value for the broker host.
4. Remove the old hash from the bindings secret (another version). Sessions
   holding a cached token keep it until it expires; nothing else is affected. No
   account, App, or key changes.

**The App private key** (rotate when it might have been exposed, or yearly):

1. GitHub › the App's settings › *Private keys* › *Generate a private key*
   (GitHub allows two at once).
2. `gcloud secrets versions add "$(terraform output -raw app_key_secret)" --data-file=<new>.pem`
   from the broker's `terraform/`. Wait at least 90s for the 60s key cache.
3. Only then delete the old key in the App settings. No environment or bearer
   changes.

**The App itself** is registered once under `sprue.works` (public visibility so
it installs on the personal account too; permissions Contents read & write, Pull
requests read & write, Issues read & write, Checks read, Metadata read; no
webhook), installed on each factory repo with *Only select repositories*. Adding
a factory repo = install the App on it, create its implementer environment with a
fresh bearer, add that bearer's hash to the bindings secret bound to the repo.

## Isolation test (spec 2d item 4, the 8b acceptance test)

From a session in `factory-implementer-<A>`:

```bash
"${CLAUDE_TICKET_WORKFLOW_ROOT:?}/scripts/factory-isolation-test" --bound OWNER/A --foreign OWNER/B
```

It tries the broker directly with `repository: B` and with no repository,
replays the helper for B, scans the environment for bearer-shaped or PEM values,
then with a normally minted A token (passed to curl through a 0600 config file,
never on a command line) checks `/installation/repositories` lists only A, that
the token carries exactly the five permissions, and that a blob write to B is
rejected. A public B's metadata is readable by anyone, so `GET /repos/B` is
reported but not judged. Only an expected refusal passes a negative path: a
broker that is down, answers 5xx, or answers 401 (no bearer reached it) is
reported as inconclusive and fails, and so does a helper that stops on
proxy-injected mode (exit 3) instead of refusing the repository (exit 4).
The write probe accepts a 404 only when `B`'s existence is independently
confirmed (an unauthenticated read of it succeeds), since GitHub answers 404
both for "you may not" and "no such repository" — so pick a `--foreign` the App
is installed on and whose existence can be verified, not an arbitrary name.
`--skip-github` runs the broker/helper/environment paths only — what CI runs
against the fake broker in `tests/`. Record the output in the PR that enables
item 4b.
