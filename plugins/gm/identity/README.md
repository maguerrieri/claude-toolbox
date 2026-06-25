# Identity provisioning (follow-on infra)

Gives each shipped **persona** its own commit identity + avatar on campaign git
history. **The plugin works without any of this** — provisioning only lights up the
per-persona avatars.

## Your domain stays out of the repo

The committed default `identity_domain` is `gm.invalid` (non-routable; no avatars).
To use a real domain, set it **locally — never committed:**

- **direnv / env:** `export GM_IDENTITY_DOMAIN=your-domain.com` and
  `export GM_IDENTITY_SEAT=you@your-domain.com` (see `.envrc.example`), or
- **a file:** copy `identity.json` to `identity.local.json` (gitignored) and edit it.

Resolution order: **env var → `identity.local.json` → committed `identity.json`.**
Each persona's email is `<persona-slug>@${identity_domain}`.

## Provision (Google Workspace: one alias per persona on a single seat)

With your domain set, add an alias per persona to the seat via the Admin SDK:

```
uv run --with google-api-python-client --with google-auth \
  plugins/gm/identity/add-aliases.py --creds <service-account.json>
```

The service account needs the `admin.directory.user.alias` scope (≤30 aliases/user — ample). **No DNS change** — MX already routes the domain to Workspace. `--dry-run` previews.

Then register each alias's Gravatar with that persona's glyph from `../assets/avatars/` (Gravatar has no clean API/Terraform path, so this is a one-time manual step).

## Fork it

Set your own `GM_IDENTITY_DOMAIN` / `GM_IDENTITY_SEAT` and run the script. Not on Workspace? Use a **Cloudflare email-routing catch-all** (`*@<domain>` → your inbox, terraformable via `cloudflare_email_routing_catch_all`) instead of Workspace aliases, then register the Gravatars.
