"""The GM screen at rest: every file under a campaign's .gm/ is sealed on disk.

Sealing is a light, reversible encoding (zlib + base64 under a one-line header). It
guards against a glance, not a determined reader: whatever shows a changed file —
Claude Code's Bash edit-diff view, `cat`, an editor preview, `git diff` — shows noise
instead of the secret. bin/campaign, bin/forge and bin/roll read sealed and legacy
plaintext files alike, so a campaign written before sealing keeps working; `seal_tree`
seals whatever plaintext is left.

Standard library only; shared by the bin/ scripts (they put this directory on
sys.path).
"""
import base64
import binascii
import os
import tempfile
import zlib

MAGIC = "gm-sealed v1"
HEADER = MAGIC + " — behind the GM screen; read with campaign gm-reveal or roll table\n"
SCREEN_DIR = ".gm"
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


def behind_screen(path):
    """Whether `path` lies inside a .gm/ directory."""
    parts = os.path.abspath(path).split(os.sep)
    return SCREEN_DIR in parts[:-1]


def seal_tree(campaign):
    """Seal every plaintext file under <campaign>/.gm/ in place; returns the count.

    Leftovers are legacy files from before sealing, and a draft a crashed sealing
    subagent never consumed. A file that isn't UTF-8 text is left alone."""
    root = os.path.join(campaign, SCREEN_DIR)
    sealed = 0
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            if name.startswith(".tmp-"):
                continue
            p = os.path.join(dirpath, name)
            if os.path.islink(p) or not os.path.isfile(p):
                continue
            try:
                with open(p, encoding="utf-8") as f:
                    data = f.read()
            except (OSError, UnicodeDecodeError):
                continue
            if is_sealed(data):
                continue
            _write_atomic(p, seal(data))
            sealed += 1
    return sealed
