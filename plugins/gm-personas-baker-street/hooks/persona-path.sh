#!/usr/bin/env bash
# SessionStart — put this pack's personas on the gm search path.
#
# gm resolves a bare `persona:` name campaign-local -> $GM_PERSONA_PATH -> its own
# personas/. A pack has no other way to announce itself: Claude Code exposes no
# cross-plugin discovery API, and ${CLAUDE_PLUGIN_ROOT} is known only inside a hook.
# So the handshake is this — append our personas/ to GM_PERSONA_PATH via
# CLAUDE_ENV_FILE, which is writable from SessionStart only.
#
# APPEND, never prepend: entries the player set themselves (direnv, their own dirs)
# must keep winning over a pack's. gm takes the first entry holding the named
# persona.md, so ours is the fallback, and the plugin's shipped four remain the last
# resort after us.
#
# Fails open at every step: a persona pack must never keep a session from starting.
set -uo pipefail

# Only a hook knows where the plugin was installed; without it there is nothing to add.
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] || exit 0
[ -n "${CLAUDE_ENV_FILE:-}" ] || exit 0

personas_dir="$CLAUDE_PLUGIN_ROOT/personas"
[ -d "$personas_dir" ] || exit 0

# `${VAR:+$VAR:}` keeps the separator off an unset/empty GM_PERSONA_PATH, which would
# otherwise leave a leading colon — an empty entry gm has to skip.
#
# %q-quote the directory: an install path with a space in it would otherwise split
# into two bogus entries when the env file is sourced.
printf 'export GM_PERSONA_PATH="${GM_PERSONA_PATH:+$GM_PERSONA_PATH:}"%q\n' \
	"$personas_dir" >>"$CLAUDE_ENV_FILE" 2>/dev/null || true

exit 0
