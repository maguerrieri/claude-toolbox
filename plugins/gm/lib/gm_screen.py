"""The GM screen at rest: every file under a campaign's .gm/ is sealed on disk.

Sealing is a light, reversible encoding (zlib + base64 under a one-line header). It
guards against a glance, not a determined reader: whatever shows a changed file —
Claude Code's Bash edit-diff view, `cat`, an editor preview, `git diff` — shows noise
instead of the secret. bin/campaign, bin/forge and bin/roll read sealed and legacy
plaintext files alike, so a campaign written before sealing keeps working; `sweep`
seals whatever plaintext is left.

The one exception is a draft: the gm:screen subagent writes a secret in plaintext under
.gm/forge/ or .gm/inbox/ (the Write tool can't seal) and the CLI that seals it deletes
it in the same command. A draft is never sealed in place or committed; `sweep` drops
one only once it is stale, since a fresh one may still be being written.

Standard library only; shared by the bin/ scripts (they put this directory on
sys.path).
"""
import base64
import binascii
import contextlib
import os
import tempfile
import time
import zlib

try:
    import fcntl
except ImportError:  # not POSIX: writers just aren't serialized
    fcntl = None

MAGIC = "gm-sealed v1"
HEADER = MAGIC + " — behind the GM screen; read with campaign gm-reveal or roll table\n"
SCREEN_DIR = ".gm"
DRAFT_DIRS = ("forge", "inbox")  # the gm:screen subagent's plaintext drafts
DRAFT_TTL = 3600  # seconds after which a draft is a crashed subagent's leftover
LOCK = ".lock"
WIDTH = 76


def seal(text):
    """`text` sealed: the header line, then the wrapped base64 of its zlib stream."""
    blob = base64.b64encode(zlib.compress(text.encode("utf-8"), 9)).decode("ascii")
    lines = [blob[i:i + WIDTH] for i in range(0, len(blob), WIDTH)]
    return HEADER + "\n".join(lines) + "\n"


def is_sealed(data):
    return data.startswith(MAGIC)


def unseal(data):
    """The plaintext of sealed `data`; legacy plaintext passes through unchanged."""
    if not is_sealed(data):
        return data
    body = "".join(data.splitlines()[1:])
    try:
        return zlib.decompress(base64.b64decode(body, validate=True)).decode("utf-8")
    except (binascii.Error, zlib.error, UnicodeDecodeError, ValueError) as e:
        raise ValueError(f"corrupt sealed data ({e})") from None


def read(path):
    """A file's plaintext, whether it is sealed or not."""
    with open(path, encoding="utf-8") as f:
        data = f.read()
    try:
        return unseal(data)
    except ValueError as e:
        raise ValueError(f"{path}: {e}") from None


def _write_atomic(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write(path, text):
    """Write `text` to `path` sealed, replacing the file in one step."""
    _write_atomic(path, seal(text))


def screen_of(path):
    """The campaign screen (`<campaign>/.gm`) that `path` lies inside, or None.

    Only the .gm/ next to a campaign's campaign.md counts, so a campaign that merely
    lives under some other `.gm` directory keeps its open tables open."""
    p = os.path.dirname(os.path.abspath(path))
    while True:
        if (os.path.basename(p) == SCREEN_DIR
                and os.path.isfile(os.path.join(os.path.dirname(p), "campaign.md"))):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


IGNORE = ("# gm: the gm:screen subagent's plaintext drafts and the screen's lock\n"
          "# never belong in history\n/forge/\n/inbox/\n/.lock\n")


def ignore_drafts(screen):
    """Give the screen a .gitignore keeping drafts and the lock out of any commit: gm's
    own checkpoints, and a deferred campaign's host repo (an Obsidian vault) alike."""
    p = os.path.join(screen, ".gitignore")
    if os.path.isdir(screen) and not os.path.exists(p):
        with open(p, "w", encoding="utf-8") as f:
            f.write(IGNORE)


@contextlib.contextmanager
def locked(screen):
    """Hold the screen's lock: one writer at a time across the CLIs and the hooks' sweep,
    so a sweep can't rewrite a file a CLI is changing or resurrect a consumed draft."""
    os.makedirs(screen, exist_ok=True)
    ignore_drafts(screen)
    if fcntl is None:
        yield
        return
    with open(os.path.join(screen, LOCK), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        yield


def _is_draft(screen, path):
    rel = os.path.relpath(path, screen).split(os.sep)
    return len(rel) > 1 and rel[0] in DRAFT_DIRS


def _starts_sealed(path):
    with open(path, "rb") as f:
        return f.read(len(MAGIC.encode("ascii"))) == MAGIC.encode("ascii")


def sweep(campaign, now=None):
    """Seal every plaintext file under <campaign>/.gm/ in place, and delete stale drafts.

    Returns (sealed, dropped). Leftover plaintext is a legacy file from before sealing;
    a stale draft is one a crashed gm:screen subagent never consumed. A fresh draft is
    left alone (its subagent may still be writing it), as are dotfiles and anything that
    isn't UTF-8 text."""
    screen = os.path.join(campaign, SCREEN_DIR)
    if not os.path.isdir(screen):
        return 0, 0
    now = time.time() if now is None else now
    sealed = dropped = 0
    with locked(screen):
        for dirpath, _dirs, files in os.walk(screen):
            for name in files:
                p = os.path.join(dirpath, name)
                if name.startswith(".") or os.path.islink(p) or not os.path.isfile(p):
                    continue
                if _is_draft(screen, p):
                    if now - os.path.getmtime(p) > DRAFT_TTL:
                        os.remove(p)
                        dropped += 1
                    continue
                if _starts_sealed(p):
                    continue
                try:
                    with open(p, encoding="utf-8") as f:
                        data = f.read()
                except (OSError, UnicodeDecodeError):
                    continue
                _write_atomic(p, seal(data))
                sealed += 1
    return sealed, dropped
