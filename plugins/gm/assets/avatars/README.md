# Persona avatars

Each persona's `chronicle_identity.avatar` points at a glyph here (e.g. `house.png`).

These are **follow-on infra** — the plugin works without them. The glyphs and their
per-alias Gravatar registration are provisioned via `../../identity/` (see its README).
Until provisioned, the `avatar` field is informational; campaign commits render with a
default identicon. Drop a square PNG per persona here, named to match the persona slug.
