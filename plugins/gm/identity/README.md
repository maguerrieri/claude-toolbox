# Identity provisioning (follow-on infra)

Gives each shipped **persona** its own commit identity + avatar on campaign git
history — so a Grognard campaign's checkpoints are authored by "Grognard Claude"
with a grognard glyph. **The plugin works without any of this**; provisioning only
lights up the per-persona avatars.

## How it works

- Each persona's `chronicle_identity.email` is `<persona-slug>@${identity_domain}`.
- `${identity_domain}` (and the backing `seat`) come from `identity.json` (default `gm.invalid`).
- The shipped addresses are **aliases on one mailbox** (the `seat`): N personas = N aliases = N Gravatar identities, one inbox.
- Avatars are a *host* feature keyed off the commit email — register each alias's glyph on Gravatar and it renders on GitHub / GitLab / Gitea / most git GUIs (a bare terminal stays text-only).

## Provision the default (gm.invalid: Cloudflare DNS + Google Workspace, `claude@` seat exists)

1. **Aliases** — add each `<persona>@<domain>` as an alias on the seat via the Admin SDK Directory API:
   ```
   uv run --with google-api-python-client --with google-auth \
     plugins/gm/identity/add-aliases.py --creds <service-account.json>
   ```
   The service account needs the `admin.directory.user.alias` scope (≤30 aliases/user — ample). **No DNS change** is needed — MX already routes the domain to Workspace. Use `--dry-run` to preview.
2. **Gravatars** — for each alias, register a Gravatar and upload that persona's glyph from `assets/avatars/`. Gravatar has no clean API/Terraform path, so this is a one-time manual step (or scripted against Gravatar's XML-RPC API).

## Fork it to your own identity

Set `identity_domain` + `seat` in `identity.json` to your domain, then:
- **Google Workspace:** run `add-aliases.py` with your admin creds.
- **Cloudflare email routing:** instead of Workspace aliases, add a catch-all forwarding `*@<domain>` to your inbox — terraformable via `cloudflare_email_routing_catch_all` + a forward rule.
- Register your glyphs on each alias's Gravatar.

That single `identity_domain` variable is the only knob; the personas and this module both read it.
