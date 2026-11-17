"""The band on the desktop surface, through the engine itself (#345).

band.test.tsx mounts the band on the desktop tree through the test kit, which
stands for the engine. This drives a real headless Claude Code over stdio, the
transport a session the desktop app hosts on its own machine uses, as a client
of the `desktop` surface would: it attaches, asks for the AbovePrompt band,
presses Show, and runs /ledger-band, through the control requests the CLI
documents as @internal (`ui_attach`, `ui_render`, `ui_press`; checked on
2.1.325 and 2.1.326). No step starts a model turn, so it needs no login.

What it can't cover is a Remote Control session (one `claude remote-control`
spawns, `--sdk-url`), whose transport is remote: AGENTS.md, *Mods in the
desktop app*, has what was checked there.

    python3 -I plugins/ledger/tests/test-band-desktop.py

CLAUDE_BIN names the CLI to run (default `claude`), split as a shell would.
"""
import json
import os
import select
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
STEP_SECONDS = 90

passed = 0
failed = 0


def record(label, ok, got=None):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
        print(f"FAIL: {label}" + ("" if got is None else f": got {json.dumps(got)[:600]}"))


def texts(node):
    """Every string drawn under <node>, in order."""
    if isinstance(node, str):
        return [node]
    if not isinstance(node, dict):
        return []
    return [text for child in node.get("children", []) for text in texts(child)]


def buttons(node):
    """Every Button under <node>, as (key, press)."""
    if not isinstance(node, dict):
        return []
    own = [(node["props"]["key"], node["press"])] if node.get("type") == "Button" else []
    return own + [button for child in node.get("children", []) for button in buttons(child)]


class Session:
    """A headless session spoken to over stream-json, as an SDK host does."""

    def __init__(self, argv, env, cwd):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env=env, cwd=cwd, text=True, bufsize=1)
        self.count = 0
        self.seen = []

    def write(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def messages(self, until):
        """Read messages until <until>(message) holds; answer that one, or None."""
        deadline = time.time() + STEP_SECONDS
        while time.time() < deadline:
            ready, _, _ = select.select([self.proc.stdout], [], [], 0.5)
            if not ready:
                continue
            line = self.proc.stdout.readline()
            if not line:
                return None
            try:
                message = json.loads(line)
            except ValueError:
                continue
            self.seen.append(message)
            if until(message):
                return message
        return None

    def ask(self, request):
        """Send a control request; answer its response's body, or None."""
        self.count += 1
        request_id = f"r{self.count}"
        self.write({"type": "control_request", "request_id": request_id, "request": request})
        answer = self.messages(lambda m: m.get("type") == "control_response"
                               and m.get("response", {}).get("request_id") == request_id)
        response = (answer or {}).get("response", {})
        return response.get("response") if response.get("subtype") == "success" else None

    def type_command(self, text, instance_id):
        """
        Type <text> as the person would, then wait for the engine to tell the
        surface that <instance_id> changed: the command's `result` can arrive
        before its write to the band's state lands, and a surface redraws on
        the `ui_invalidate` that follows. Answers the messages seen meanwhile.
        """
        start = len(self.seen)
        self.write({"type": "user", "message": {"role": "user", "content": text}})

        def invalidates(message):
            return message.get("subtype") == "ui_invalidate" and any(
                instance.get("instance_id") == instance_id for instance in message.get("instances", []))

        self.messages(lambda m: m.get("type") == "result")
        if not any(invalidates(message) for message in self.seen[start:]):
            self.messages(invalidates)
        return self.seen[start:]

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        return self.proc.stderr.read()


def main():
    work = tempfile.mkdtemp(prefix="ledger-band-desktop.")
    try:
        run(work)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print(f"{passed} passed, {failed} failed")
    return 0 if failed == 0 else 1


def run(work):
    me = str(uuid.uuid4())
    ledgers = os.path.join(work, "ledgers")
    home = os.path.join(work, "home")
    os.makedirs(ledgers)
    os.makedirs(home)
    need = {"kind": "need", "id": "n1", "why": "the owner reviews before a merge", "text": "Review PR #9",
            "ref": "o/r#9", "at": "2026-11-17T20:40:13Z"}
    with open(os.path.join(ledgers, f"{me}.jsonl"), "w") as ledger:
        ledger.write(json.dumps(need) + "\n")

    # Nothing of the person running it: no settings but the project's (none
    # here), no MCP servers, a home of its own, and the band's directory.
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "CLAUDE_SESSION_LEDGER_DIR": ledgers}
    argv = shlex.split(os.environ.get("CLAUDE_BIN", "claude")) + [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "project", "--strict-mcp-config", "--plugin-dir", PLUGIN,
        "--session-id", me, "--model", "haiku",
    ]
    session = Session(argv, env, work)
    try:
        steps(session, me, ledgers, env)
    finally:
        stderr = session.close()
    if failed and stderr.strip():
        print("stderr:", stderr.strip()[:2000])


def steps(session, me, ledgers, env):
    init = session.ask({"subtype": "initialize"})
    capabilities = (init or {}).get("capabilities", [])
    record("a local transport offers remote surfaces (ui_surface_v1)", "ui_surface_v1" in capabilities,
           [c for c in capabilities if c.startswith("ui_")])
    # Let session.start's first read of the ledger land.
    time.sleep(2)

    attach = session.ask({"subtype": "ui_attach", "surface": "desktop", "client_id": "test"})
    record("a desktop client attaches", (attach or {}).get("surfaces") == ["desktop"], attach)

    props = {"hasSurvey": False, "isCollapsed": False, "isWorking": False, "maxRows": 12, "bodyColumns": 95,
             "scroll": {"offset": 0, "bodyRows": 11}, "view": {}}

    def band():
        return session.ask({"subtype": "ui_render", "surface": "desktop", "client_id": "test",
                            "component": "AbovePrompt", "instance_id": "above-prompt", "props": props}) or {}

    folded = band()
    tree = folded.get("tree", {})
    record("the band draws its row on desktop", folded.get("drawn_by") == ["ledger"], folded)
    record("the row shows the count and the newest need",
           [t.strip() for t in texts(tree)] == ["1 open need", "Review PR #9"], texts(tree))
    keys = dict(buttons(tree))
    record("the folded row has Show and Hide", list(keys) == ["show", "hide"], list(keys))

    pressed = session.ask({"subtype": "ui_press", "surface": "desktop", "client_id": "test", "key": "show",
                           **keys.get("show", {})}) if "show" in keys else None
    record("Show is pressed on desktop", (pressed or {}).get("handled") is True, pressed)

    expanded = band().get("tree", {})
    resolve = f"resolve:{me}:n1"
    record("Show expands the list, with Less and Resolve",
           [key for key, _ in buttons(expanded)] == ["less", "hide", resolve], [key for key, _ in buttons(expanded)])
    record("the list shows the need's ref, text and Why line",
           "Review PR #9" in texts(expanded) and "Why: the owner reviews before a merge" in texts(expanded)
           and any(t.startswith("n1 · o/r#9 · ") for t in texts(expanded)), texts(expanded))

    session.type_command("/ledger-band", "above-prompt")
    record("/ledger-band folds it", [key for key, _ in buttons(band().get("tree", {}))] == ["show", "hide"])
    session.type_command("/ledger-band", "above-prompt")
    record("/ledger-band expands it again", resolve in [key for key, _ in buttons(band().get("tree", {}))])

    # Resolved as the session would resolve it, through the script: a Resolve
    # press also starts a turn (it tells the session), which needs a model.
    # band.test.tsx presses Resolve on the desktop tree.
    resolved = subprocess.run(["bash", os.path.join(PLUGIN, "scripts", "ledger.sh"), "resolve", "n1"],
                              env={**env, "CLAUDE_CODE_SESSION_ID": me}, capture_output=True, text=True)
    record("the need resolves", resolved.returncode == 0, resolved.stderr)
    said = session.type_command("/ledger-band", "above-prompt")
    record("/ledger-band then says the session needs nothing",
           "This session needs nothing from you." in json.dumps(said), [m.get("type") for m in said])
    # A band with nothing open hands on, so the answer is the engine's own node
    # (`drawn_by` still names every plugin hooked on the band).
    gone = band()
    record("the row is gone once nothing is open", gone.get("tree", {}).get("type") == "engine", gone)


if __name__ == "__main__":
    sys.exit(main())
