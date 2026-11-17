"""The band on the desktop surface, through the engine itself (#345).

band.test.tsx mounts the band on the desktop tree through the test kit, which
stands for the engine. This drives a real headless Claude Code over stdio, the
transport a session the desktop app hosts on its own machine uses, as a client
of the `desktop` surface would: it attaches, asks for the AbovePrompt band,
presses Show, and runs /ledger-band, through the control requests the CLI
documents as @internal (`ui_attach`, `ui_render`, `ui_press`). It passes on
2.1.326 and on 2.1.325, the CLI ledger CI pins. No step starts a model turn,
so it needs no login.

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
import traceback
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
# How long one request, or a command's turn, may take before it counts as
# unanswered; the engine answers each in well under a second once loaded.
STEP_SECONDS = 60
# How long the first ask may wait for session.start's first read of the ledger.
FIRST_DRAW_SECONDS = 30
# How long the band may take to show a change: a command's `result` can
# arrive before its write to the band's state lands.
SETTLE_SECONDS = 10

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
    """Every Button under <node>, as (key, press); a malformed one has None in either."""
    if not isinstance(node, dict):
        return []
    own = [((node.get("props") or {}).get("key"), node.get("press"))] if node.get("type") == "Button" else []
    return own + [button for child in node.get("children", []) for button in buttons(child)]


def button_keys(node):
    return [key for key, _ in buttons(node)]


def tree_of(answer):
    """The tree a ui_render answered, or {} for none (an error, or a null tree)."""
    return answer.get("tree") or {}


class Session:
    """A headless session spoken to over stream-json, as an SDK host does."""

    def __init__(self, argv, env, cwd, stderr_path):
        # stderr goes to a file, so a chatty CLI can never fill a pipe nobody
        # reads and stall. stdout is read straight off its descriptor: a
        # buffered reader would pull several lines in at once, which select()
        # then never reports.
        self.stderr = open(stderr_path, "w+")
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.stderr,
                                     env=env, cwd=cwd)
        self.fd = self.proc.stdout.fileno()
        self.pending = b""
        self.ended = False
        self.count = 0
        self.seen = []

    def write(self, message):
        # A CLI that already exited can't be written to: the read that follows
        # then answers nothing, which the caller records.
        try:
            self.proc.stdin.write((json.dumps(message) + "\n").encode())
            self.proc.stdin.flush()
        except BrokenPipeError:
            self.ended = True

    def next_line(self, deadline):
        """The next line of stdout, or None at the deadline or once it ends."""
        while b"\n" not in self.pending:
            if self.ended:
                # A last line the CLI didn't end with a newline still counts.
                line, self.pending = self.pending, b""
                return line or None
            left = deadline - time.time()
            if left <= 0:
                return None
            ready, _, _ = select.select([self.fd], [], [], min(left, 0.5))
            if ready:
                chunk = os.read(self.fd, 65536)
                if chunk:
                    self.pending += chunk
                else:
                    self.ended = True
        line, self.pending = self.pending.split(b"\n", 1)
        return line

    def messages(self, until, seconds=STEP_SECONDS):
        """Read messages until <until>(message) holds; answer that one, or None."""
        deadline = time.time() + seconds
        while True:
            line = self.next_line(deadline)
            if line is None:
                return None
            try:
                message = json.loads(line)
            except ValueError:
                continue
            self.seen.append(message)
            if until(message):
                return message

    def ask(self, request):
        """
        Send a control request; answer its response's body, or {"error": why}
        when the engine refused it or never answered.
        """
        self.count += 1
        request_id = f"r{self.count}"
        self.write({"type": "control_request", "request_id": request_id, "request": request})
        answer = self.messages(lambda m: m.get("type") == "control_response"
                               and m.get("response", {}).get("request_id") == request_id)
        if answer is None:
            return {"error": f"no answer to {request['subtype']}" + (" (the CLI exited)" if self.ended else "")}
        response = answer.get("response", {})
        if response.get("subtype") != "success":
            return {"error": response.get("error", response)}
        return response.get("response") or {}

    def type_command(self, text):
        """
        Type <text> as the person would and wait for its turn's `result`.
        Answers the messages seen meanwhile, and whether the result came.
        """
        start = len(self.seen)
        self.write({"type": "user", "message": {"role": "user", "content": text}})
        ended = self.messages(lambda m: m.get("type") == "result") is not None
        return self.seen[start:], ended

    def close(self):
        try:
            self.proc.stdin.close()
        except BrokenPipeError:
            pass
        try:
            self.proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.stderr.seek(0)
        said = self.stderr.read()
        self.stderr.close()
        return said


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

    # None of the person's own setup: no settings but the project's (none
    # here), no MCP servers, a home of its own, and the band's directory.
    # Settings a machine's administrator manages still apply.
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "CLAUDE_SESSION_LEDGER_DIR": ledgers}
    argv = shlex.split(os.environ.get("CLAUDE_BIN", "claude")) + [
        "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--setting-sources", "project", "--strict-mcp-config", "--plugin-dir", PLUGIN,
        "--session-id", me, "--model", "haiku",
    ]
    session = Session(argv, env, work, os.path.join(work, "stderr.txt"))
    try:
        steps(session, me, env)
    except Exception:
        # A crash is a failure like any other, so the tally and the CLI's
        # stderr still print.
        record("the steps run to their end", False, traceback.format_exc()[-1500:])
    finally:
        stderr = session.close()
    if failed and stderr.strip():
        print("stderr:", stderr.strip()[:2000])


def steps(session, me, env):
    init = session.ask({"subtype": "initialize"})
    capabilities = init.get("capabilities") or []
    record("a local transport offers remote surfaces (ui_surface_v1)", "ui_surface_v1" in capabilities,
           init.get("error") or [c for c in capabilities if c.startswith("ui_")])

    attach = session.ask({"subtype": "ui_attach", "surface": "desktop", "client_id": "test"})
    record("a desktop client attaches", attach.get("surfaces") == ["desktop"], attach)

    props = {"hasSurvey": False, "isCollapsed": False, "isWorking": False, "maxRows": 12, "bodyColumns": 95,
             "scroll": {"offset": 0, "bodyRows": 11}, "view": {}}

    def band():
        return session.ask({"subtype": "ui_render", "surface": "desktop", "client_id": "test",
                            "component": "AbovePrompt", "instance_id": "above-prompt", "props": props})

    def band_until(holds, seconds=SETTLE_SECONDS):
        """
        Ask for the band until <holds>(answer), the engine refuses, or the time
        is up; answer the last answer. A state write can land after the step
        that made it answered, and a surface redraws when the engine says so.
        """
        deadline = time.time() + seconds
        answer = band()
        while "error" not in answer and not holds(answer) and time.time() < deadline:
            time.sleep(0.25)
            answer = band()
        return answer

    # session.start reads the ledger once it has loaded, so the first draw
    # waits for the row rather than guessing how long that takes.
    folded = band_until(lambda a: tree_of(a).get("type") != "engine", FIRST_DRAW_SECONDS)
    tree = tree_of(folded)
    record("the band draws its row on desktop", folded.get("drawn_by") == ["ledger"] and tree.get("type") == "Box",
           folded)
    record("the row shows the count and the newest need",
           [t.strip() for t in texts(tree)] == ["1 open need", "Review PR #9"], texts(tree))
    keys = dict(buttons(tree))
    record("the folded row has Show and Hide", list(keys) == ["show", "hide"], list(keys))

    show = keys.get("show") or {}
    pressed = session.ask({"subtype": "ui_press", "surface": "desktop", "client_id": "test", "key": "show", **show})
    record("Show is pressed on desktop", pressed.get("handled") is True, pressed)

    resolve = f"resolve:{me}:n1"
    expanded = tree_of(band_until(lambda a: button_keys(tree_of(a)) == ["less", "hide", resolve]))
    record("Show expands the list, with Less and Resolve", button_keys(expanded) == ["less", "hide", resolve],
           button_keys(expanded))
    record("the list shows the need's ref, text and Why line",
           "Review PR #9" in texts(expanded) and "Why: the owner reviews before a merge" in texts(expanded)
           and any(t.startswith("n1 · o/r#9 · ") for t in texts(expanded)), texts(expanded))

    _, ended = session.type_command("/ledger-band")
    folded_again = button_keys(tree_of(band_until(lambda a: button_keys(tree_of(a)) == ["show", "hide"])))
    record("/ledger-band folds it", ended and folded_again == ["show", "hide"],
           {"result came": ended, "buttons": folded_again})
    _, ended = session.type_command("/ledger-band")
    expanded_again = button_keys(tree_of(band_until(lambda a: resolve in button_keys(tree_of(a)))))
    record("/ledger-band expands it again", ended and resolve in expanded_again,
           {"result came": ended, "buttons": expanded_again})

    # Resolved as the session would resolve it, through the script: a Resolve
    # press also starts a turn (it tells the session), which needs a model.
    # band.test.tsx presses Resolve on the desktop tree.
    try:
        resolved = subprocess.run(["bash", os.path.join(PLUGIN, "scripts", "ledger.sh"), "resolve", "n1"],
                                  env={**env, "CLAUDE_CODE_SESSION_ID": me}, capture_output=True, text=True,
                                  timeout=STEP_SECONDS)
        record("the need resolves", resolved.returncode == 0, resolved.stderr)
    except subprocess.TimeoutExpired:
        record("the need resolves", False, f"ledger.sh resolve took over {STEP_SECONDS}s")
    said, ended = session.type_command("/ledger-band")
    record("/ledger-band then says the session needs nothing",
           ended and "This session needs nothing from you." in json.dumps(said),
           {"result came": ended, "messages": [m.get("type") for m in said]})
    # A band with nothing open hands on, so the answer is the engine's own node
    # (`drawn_by` still names every plugin hooked on the band).
    gone = band_until(lambda a: tree_of(a).get("type") == "engine")
    record("the row is gone once nothing is open", tree_of(gone).get("type") == "engine", gone)


if __name__ == "__main__":
    sys.exit(main())
