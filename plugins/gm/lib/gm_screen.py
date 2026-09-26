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


def _mode_for(path):
    """The permissions a rewrite of `path` keeps: the file's own (its target's, for a
    link), or the umask default for a new file. mkstemp's 0600 must not leak into a
    shared vault or a synced folder."""
    try:
        return os.stat(path).st_mode & 0o7777
    except OSError:
        umask = os.umask(0)
        os.umask(umask)
        return 0o666 & ~umask


def _write_atomic(path, data):
    """Replace `path` with `data` in one step. A symlink at `path` is replaced itself,
    not written through (upkeep's rule; `write` resolves links first)."""
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    mode = _mode_for(path)
    fd, tmp = tempfile.mkstemp(dir=parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write(path, text):
    """Write `text` to `path` sealed, replacing the file in one step. An explicit write
    goes wherever the player's filesystem points: a symlink is written through."""
    _write_atomic(os.path.realpath(path), seal(text))


def _screen_above(p):
    while True:
        if (os.path.basename(p) == SCREEN_DIR
                and os.path.isfile(os.path.join(os.path.dirname(p), "campaign.md"))):
            return p
        parent = os.path.dirname(p)
        if parent == p:
            return None
        p = parent


def screen_of(path):
    """The campaign screen (`<campaign>/.gm`) that `path` lies inside, or None.

    Only the .gm/ next to a campaign's campaign.md counts, so a campaign that merely
    lives under some other `.gm` directory keeps its open tables open. Symlinks count in
    both directions: a path is behind the screen if it resolves there, or if it sits
    there and resolves elsewhere, so no link turns a sealed write into a plaintext one."""
    return (_screen_above(os.path.dirname(os.path.realpath(path)))
            or _screen_above(os.path.dirname(os.path.abspath(path))))


IGNORE_HEADER = "# gm: the gm:screen subagent's plaintext drafts never belong in history\n"
IGNORED = ["/" + d + "/" for d in DRAFT_DIRS]


def _maintainable(screen):
    """Whether automatic upkeep (the sweep, the .gitignore) may touch this screen: a real
    directory, not a symlink. Upkeep runs unprompted, from hooks and checkpoints, so it
    never follows a link out of the campaign; an explicit gm-* command still writes
    wherever the player's filesystem points."""
    return os.path.isdir(screen) and not os.path.islink(screen)


def _ignore_drafts(screen):
    """Make the screen's .gitignore keep drafts out of any commit: gm's own checkpoints,
    and a deferred campaign's host repo (an Obsidian vault) alike. Rules already there
    are kept; the missing ones are added in one atomic write, which also swaps a
    symlinked .gitignore for a local copy (upkeep never writes through a link). Call it
    only under `locked`, which does."""
    if not _maintainable(screen):
        return
    p = os.path.join(screen, ".gitignore")
    try:
        with open(p, encoding="utf-8") as f:
            existing = f.read()
    except (OSError, UnicodeDecodeError):
        existing = ""
    have = {line.strip() for line in existing.splitlines()}
    missing = [rule for rule in IGNORED if rule not in have]
    if not missing and not os.path.islink(p):
        return
    lead = "" if not existing or existing.endswith("\n") else "\n"
    head = IGNORE_HEADER if not existing else ""
    _write_atomic(p, existing + lead + head + "".join(rule + "\n" for rule in missing))


@contextlib.contextmanager
def locked(screen):
    """Hold the screen's lock: one writer at a time across the CLIs and the hooks' sweep,
    so a sweep can't rewrite a file a CLI is changing or resurrect a consumed draft. The
    lock is a flock on the .gm directory itself, so there's no lock file to manage; the
    .gitignore upkeep happens inside it."""
    os.makedirs(screen, exist_ok=True)
    if fcntl is None:
        _ignore_drafts(screen)
        yield
        return
    fd = os.open(screen, os.O_RDONLY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        _ignore_drafts(screen)
        yield
    finally:
        os.close(fd)


def drop_draft_links(screen):
    """Remove every symlink in the draft dirs, file or directory; returns how many. A
    link is never a draft: gm:screen's Write would follow it and leave the plaintext
    outside the screen. Only the link goes; its target is left alone. Call under `locked`."""
    dropped = 0
    for d in DRAFT_DIRS:
        top = os.path.join(screen, d)
        if os.path.islink(top):  # the draft dir itself: drop the link, never follow it
            os.remove(top)
            dropped += 1
            continue
        if not os.path.isdir(top):
            continue
        for dirpath, dirs, files in os.walk(top):  # never descends into a linked dir
            for name in dirs + files:
                p = os.path.join(dirpath, name)
                if os.path.islink(p):
                    os.remove(p)
                    dropped += 1
    return dropped


def refuse_link(path, what):
    """Raise when a file a command would consume is a symlink: consuming it would read
    the target and delete only the link, leaving the plaintext wherever it points."""
    if os.path.islink(path):
        raise ValueError(f"refusing to consume {what} {path}: it is a symlink, so its "
                         f"plaintext would outlive the command; write the draft as a real file")


def _is_draft(screen, path):
    rel = os.path.relpath(path, screen).split(os.sep)
    return len(rel) > 1 and rel[0] in DRAFT_DIRS


def _is_metadata(screen, path):
    """The screen's own bookkeeping, never a secret: its top-level .gitignore. (A
    `_write_atomic` temp needs no exemption: every writer holds the lock the sweep
    holds, so the sweep never sees one mid-write.)"""
    return os.path.dirname(path) == screen and os.path.basename(path) == ".gitignore"


def _starts_sealed(path):
    with open(path, "rb") as f:
        return is_sealed(f.read(len(MAGIC)).decode("ascii", "replace"))


def sweep(campaign, now=None):
    """Make every entry under <campaign>/.gm/ a sealed regular file, except drafts.

    Returns (sealed, dropped). The one rule: apart from the screen's own .gitignore, what
    sits in .gm/ is sealed on disk.
    - Plaintext (a legacy file from before sealing, or any hidden file) is sealed in place.
    - A symlink is replaced by a sealed copy of the text it points to, so the screened
      path never reads as plaintext; the target itself, outside or not, is left alone.
      Symlinked directories aren't followed, .gm itself included (`_maintainable`).
    - A draft (.gm/forge/, .gm/inbox/) is never sealed in place: a fresh one may still be
      being written by its gm:screen subagent, so it is left alone until it is stale,
      then dropped (it was a crashed subagent's scratch). A symlink there, file or
      directory, is never a draft and is dropped at once (`drop_draft_links`).
    Anything that isn't UTF-8 text (or a dangling link) is left as it is."""
    screen = os.path.join(campaign, SCREEN_DIR)
    if not _maintainable(screen):
        return 0, 0
    now = time.time() if now is None else now
    sealed = 0
    with locked(screen):
        dropped = drop_draft_links(screen)
        for dirpath, _dirs, files in os.walk(screen):
            for name in files:
                p = os.path.join(dirpath, name)
                if _is_metadata(screen, p):
                    continue
                if _is_draft(screen, p):
                    if now - os.lstat(p).st_mtime > DRAFT_TTL:
                        os.remove(p)
                        dropped += 1
                    continue
                link = os.path.islink(p)
                if not os.path.isfile(p) or (not link and _starts_sealed(p)):
                    continue
                try:
                    with open(p, encoding="utf-8") as f:
                        data = f.read()
                except (OSError, UnicodeDecodeError):
                    continue
                _write_atomic(p, data if is_sealed(data) else seal(data))
                sealed += 1
    return sealed, dropped
