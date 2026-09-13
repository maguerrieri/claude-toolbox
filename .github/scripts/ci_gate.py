#!/usr/bin/env python3
"""ci-gate: aggregate a pull request's expected CI into one `factory/ci-gate` verdict.

Design (docs/superpowers/specs/2026-09-11-software-factory-design.md, section 1d):
existing CI is path-filtered, so registering it as a required check would leave a
docs-only PR pending forever, and a check *name* alone can be spoofed by a
PR-added workflow. So one unfiltered, base-branch workflow (`ci-gate.yml`) runs
this evaluator on every PR event and after every other workflow completes, and a
dedicated `factory-ci` GitHub App posts the verdict. This file is fetched from the
base branch by that workflow and never checked out from the PR.

Each evaluation:

1. asserts the repository's default branch is `main`;
2. resolves exactly one open PR targeting `main` whose head is the SHA under
   evaluation (zero -> nothing to report; more than one -> fail closed);
3. reads the PR's head tree: `.github/factory-ci.yml` (the manifest of CI
   workflows and the `pull_request` triggers they are expected under) and every
   file in `.github/workflows/`; lints the manifest against the workflows (an
   entry for ci-gate itself or for a `pull_request_target` workflow, a listed
   workflow whose actual `on:` differs, an unlisted `pull_request` workflow, a
   trigger construct this evaluator does not implement, or a ci-gate.yml whose
   own triggers or `workflow_run.workflows` list do not match all fail the
   gate). The head tree is used because it is
   the tree GitHub actually executes for the PR: expecting a workflow the PR
   removed would pend forever, and the manifest change is visible in the diff;
4. computes the expected set by evaluating each manifest entry's `types`,
   `branches`, `branches-ignore`, `paths`, and `paths-ignore` against the PR
   with GitHub's own filter semantics;
5. reads the latest attempt of every expected workflow's run on the head SHA
   (its own runs and `ci-gate.yml` are always excluded) and reports `success`
   only when every expected run exists and succeeded, `failure` if any run
   completed without succeeding, and `pending` otherwise. No expected workflow
   (a docs-only PR) is `success`;
6. fails the PR if `.claude/settings.json` (root, or any changed copy in a
   subdirectory) carries a `remote.*` key (spec section 2c);
7. fails the PR if the head tree's `.claude/cloud-setup.sh` (the provisioning
   script a factory environment runs from `origin/main`) lacks its
   never-executes-the-checkout header or contains a build-tool, package-manager,
   sourcing, or relative invocation, or if the PR removes a script the base
   carries (spec section 2b).

Stdlib plus PyYAML. The pure functions take plain data and are unit-tested in
`tests/test_ci_gate.py`; `main()` is the GitHub Actions glue.
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

SCHEMA = "factory-ci/1"
MANIFEST_PATH = ".github/factory-ci.yml"
WORKFLOWS_DIR = ".github/workflows"
SELF_WORKFLOW = "ci-gate.yml"
CHECK_NAME = "factory/ci-gate"
PROTECTED_BASE = "main"
# Only `pull_request` workflows are aggregated: a `pull_request_target`
# workflow executes the *base* branch's YAML, so its head-tree trigger config
# says nothing about whether GitHub ran it, and such workflows (ci-gate itself,
# the critic and merge workflows of 3a/3b) post their own checks anyway.
PR_EVENTS = ("pull_request",)
GATE_EVENT = "pull_request_target"
GATE_TYPES = {"opened", "synchronize", "reopened"}
GATE_TARGET_KEYS = {"types", "branches"}
GATE_RUN_KEYS = {"workflows", "types"}
GATE_DISPATCH_INPUT = "head_sha"
SUPPORTED_KEYS = {"types", "branches", "branches-ignore", "paths", "paths-ignore"}
DEFAULT_TYPES = ["opened", "synchronize", "reopened"]
HEAD_TYPES = {"opened", "synchronize"}
CLOSE_TYPES = {"closed"}
# GitHub evaluates path filters against at most 300 changed files, and runs
# every path-filtered workflow regardless when it cannot compute the diff at
# all (documented for pushes of more than 1000 commits, or a diff timeout).
MAX_CHANGED_FILES = 300
MAX_COMMITS = 1000
SETTINGS_FILE = ".claude/settings.json"
API_TIMEOUT_SECONDS = 30
CLOUD_SETUP_FILE = ".claude/cloud-setup.sh"
CLOUD_SETUP_HEADER = "NEVER EXECUTES ANYTHING FROM THE CHECKOUT"


class GateError(Exception):
    """A condition that fails the gate (lint error, unsupported construct, ...)."""


# --- GitHub filter patterns -------------------------------------------------


def pattern_to_regex(pattern: str) -> re.Pattern:
    """Translate a GitHub filter pattern (the `paths:`/`branches:` cheat sheet) to a regex.

    `*` matches any run of characters except `/`; `**` matches anything; `?` and
    `+` quantify the preceding character; `[...]` is a character class. Anything
    else is literal. Anchored at both ends.
    """
    out = []
    i, n = 0, len(pattern)
    while i < n:
        c = pattern[i]
        if c == "*":
            if pattern.startswith("**/", i):
                out.append("(?:.*/)?")  # zero or more directories: **/x matches x at the root
                i += 3
            elif pattern.startswith("**", i):
                out.append(".*")
                i += 2
            else:
                out.append("[^/]*")
                i += 1
        elif c in "?+":
            out.append(c)
            i += 1
        elif c == "[":
            j = pattern.find("]", i + 1)
            if j == -1:
                out.append(re.escape(c))
                i += 1
            else:
                out.append(pattern[i : j + 1])
                i = j + 1
        else:
            out.append(re.escape(c))
            i += 1
    try:
        return re.compile("^" + "".join(out) + "$")
    except re.error as exc:
        raise GateError(f"unsupported filter pattern {pattern!r}: {exc}") from exc


def select(patterns: list[str], value: str) -> bool | None:
    """GitHub's ordered include/negate matching: the last matching pattern decides.

    Returns True (selected), False (excluded by a `!` pattern), or None (no match).
    """
    result = None
    for pattern in patterns:
        negated = pattern.startswith("!")
        body = pattern[1:] if negated else pattern
        if pattern_to_regex(body).match(value):
            result = not negated
    return result


# --- Workflow `on:` normalization -------------------------------------------


def workflow_on(doc) -> dict:
    """The `on:` block of a parsed workflow. PyYAML reads the bare key `on` as True."""
    if not isinstance(doc, dict):
        raise GateError("workflow is not a mapping")
    on = doc.get("on", doc.get(True))
    if on is None:
        raise GateError("workflow has no `on:` block")
    return normalize_on(on)


def normalize_on(on) -> dict:
    """Canonical `{event: {key: [values]}}` form of an `on:` block."""
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {str(event): {} for event in on}
    if isinstance(on, dict):
        return {str(event): normalize_event(event, cfg) for event, cfg in on.items()}
    raise GateError(f"unsupported `on:` block: {on!r}")


def normalize_event(event: str, cfg) -> dict:
    if event not in PR_EVENTS:
        # Non-PR triggers never decide whether a workflow runs on a PR; their
        # content is irrelevant to the gate and is neither compared nor validated
        # (`schedule:` is a list, `workflow_dispatch:` may be bare, and
        # pull_request_target runs base-branch YAML: see PR_EVENTS).
        return {}
    if cfg is None:
        return {}
    if not isinstance(cfg, dict):
        raise GateError(f"{event}: trigger config must be a mapping, got {cfg!r}")
    out = {}
    for key, value in cfg.items():
        if key not in SUPPORTED_KEYS:
            raise GateError(f"{event}.{key}: trigger construct not implemented by ci-gate")
        if isinstance(value, str):
            value = [value]
        if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
            raise GateError(f"{event}.{key}: expected a string or list of strings")
        out[key] = list(value)
    return out


def pr_triggers(on: dict) -> dict:
    return {event: cfg for event, cfg in on.items() if event in PR_EVENTS}


def workflow_name(filename: str, doc) -> str:
    name = doc.get("name") if isinstance(doc, dict) else None
    return str(name) if name else f"{WORKFLOWS_DIR}/{filename}"


# --- Manifest lint ----------------------------------------------------------


def lint(manifest, workflows: dict[str, object], gate_doc) -> list[str]:
    """Errors that make the manifest unusable. Empty list means consistent.

    `workflows` maps `<file>.yml` -> parsed document for every file in the head
    tree's `.github/workflows/`; `gate_doc` is the parsed ci-gate.yml from the
    same tree (None if the PR removed it).
    """
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return [f"{MANIFEST_PATH}: not a mapping"]
    if manifest.get("schema") != SCHEMA:
        errors.append(f"{MANIFEST_PATH}: schema must be {SCHEMA!r}, got {manifest.get('schema')!r}")
    entries = manifest.get("workflows")
    if entries is None:
        entries = {}
    if not isinstance(entries, dict):
        return errors + [f"{MANIFEST_PATH}: `workflows` must be a mapping of file name -> triggers"]

    for filename, declared in entries.items():
        if filename == SELF_WORKFLOW:
            errors.append(f"{MANIFEST_PATH}: {SELF_WORKFLOW} must not list itself")
            continue
        doc = workflows.get(filename)
        if doc is None:
            errors.append(f"{MANIFEST_PATH}: {filename} is listed but {WORKFLOWS_DIR}/{filename} does not exist")
            continue
        try:
            name = doc.get("name") if isinstance(doc, dict) else None
            if not isinstance(name, str) or not name.strip():
                raise GateError("workflow has no `name:`; ci-gate subscribes to workflow_run by name, so every listed workflow needs one")
            declared_norm = normalize_on(declared if declared is not None else {})
            if set(declared_norm) - set(PR_EVENTS):
                raise GateError("manifest entries may only declare pull_request (pull_request_target workflows run "
                                "base-branch YAML and post their own checks; they are never aggregated)")
            if not declared_norm:
                raise GateError("manifest entry declares no pull_request trigger")
            actual = pr_triggers(workflow_on(doc))
            if not actual:
                raise GateError("workflow has no pull_request trigger; remove it from the manifest")
            if actual != declared_norm:
                raise GateError(
                    "manifest entry differs from the workflow's `on:` block\n"
                    f"      manifest: {json.dumps(declared_norm, sort_keys=True)}\n"
                    f"      workflow: {json.dumps(actual, sort_keys=True)}"
                )
            for event, cfg in actual.items():
                validate_constructs(event, cfg)
        except GateError as exc:
            errors.append(f"{filename}: {exc}")

    for filename, doc in sorted(workflows.items()):
        if filename == SELF_WORKFLOW or filename in entries:
            continue
        try:
            if pr_triggers(workflow_on(doc)):
                errors.append(f"{filename}: has a pull_request trigger but is not listed in {MANIFEST_PATH}")
        except GateError as exc:
            errors.append(f"{filename}: {exc}")

    if gate_doc is None:
        errors.append(f"{WORKFLOWS_DIR}/{SELF_WORKFLOW} is missing from the head tree")
    else:
        expected_names = sorted(workflow_name(f, workflows[f]) for f in entries if f in workflows)
        errors += [f"{SELF_WORKFLOW}: {e}" for e in lint_gate(gate_doc, expected_names)]
    return errors


def lint_gate(gate_doc, expected_names: list[str]) -> list[str]:
    """ci-gate.yml's own trigger shape: the head copy becomes main's after merge.

    Names alone are not enough -- a PR that drops the `pull_request_target`
    trigger, narrows its types, or changes `workflow_run.types` would stop the
    gate from evaluating new PRs or from refreshing pending ones after merge.
    """
    errors: list[str] = []
    try:
        workflow_on(gate_doc)  # parse errors surface here
    except GateError as exc:
        return [str(exc)]
    raw = gate_doc.get("on", gate_doc.get(True))
    raw = raw if isinstance(raw, dict) else {}
    target = raw.get(GATE_EVENT)
    if not isinstance(target, dict):
        errors.append(f"on.{GATE_EVENT} must be present as a mapping")
    else:
        if set(target) - GATE_TARGET_KEYS:
            # A path filter here would let GitHub skip the gate for some PRs,
            # so the required check would never be posted.
            errors.append(f"on.{GATE_EVENT} may only set {sorted(GATE_TARGET_KEYS)}, got {sorted(set(target) - GATE_TARGET_KEYS)}")
        types = set(_as_list(target.get("types")))
        if not GATE_TYPES <= types:
            errors.append(f"on.{GATE_EVENT}.types must include {sorted(GATE_TYPES)}, got {sorted(types)}")
        if _as_list(target.get("branches")) != [PROTECTED_BASE]:
            errors.append(f"on.{GATE_EVENT}.branches must be exactly [{PROTECTED_BASE!r}]")
    run = raw.get("workflow_run")
    if not isinstance(run, dict):
        errors.append("on.workflow_run must be present as a mapping")
    else:
        if set(run) - GATE_RUN_KEYS:
            # A branch filter here would stop completions on PR branches from
            # re-evaluating the gate.
            errors.append(f"on.workflow_run may only set {sorted(GATE_RUN_KEYS)}, got {sorted(set(run) - GATE_RUN_KEYS)}")
        if _as_list(run.get("types")) != ["completed"]:
            errors.append("on.workflow_run.types must be exactly ['completed']")
        names = sorted(_as_list(run.get("workflows")))
        if names != expected_names:
            errors.append(
                "on.workflow_run.workflows must list exactly the manifest's workflows\n"
                f"      ci-gate:  {names}\n"
                f"      manifest: {expected_names}"
            )
    dispatch = raw.get("workflow_dispatch") if "workflow_dispatch" in raw else None
    head_input = (dispatch.get("inputs") or {}).get(GATE_DISPATCH_INPUT) if isinstance(dispatch, dict) else None
    if not isinstance(head_input, dict) or head_input.get("required") is not True:
        errors.append(f"on.workflow_dispatch must declare a required `{GATE_DISPATCH_INPUT}` input (manual re-evaluation by head SHA)")
    return errors


def _as_list(value) -> list:
    if value is None:
        return []
    return [value] if isinstance(value, str) else list(value)


def validate_constructs(event: str, cfg: dict) -> None:
    """Reject trigger configs whose GitHub behaviour this evaluator cannot mirror."""
    types = set(cfg.get("types", DEFAULT_TYPES))
    if not HEAD_TYPES <= types and not types <= CLOSE_TYPES:
        # A workflow that runs only on e.g. `labeled` or `reopened` may or may
        # not have run for this head; ci-gate cannot know, so it refuses rather
        # than ignore a run GitHub did execute. Only `closed` is never part of
        # validating an open head.
        raise GateError(
            f"{event}.types {sorted(types)}: must include both opened and synchronize "
            "(or be only closed) for ci-gate to know whether a head SHA triggers it"
        )
    if "branches" in cfg and "branches-ignore" in cfg:
        raise GateError(f"{event}: branches and branches-ignore cannot both be set")
    if "paths" in cfg and "paths-ignore" in cfg:
        raise GateError(f"{event}: paths and paths-ignore cannot both be set")
    for key in ("branches", "branches-ignore", "paths", "paths-ignore"):
        for pattern in cfg.get(key, []):
            pattern_to_regex(pattern[1:] if pattern.startswith("!") else pattern)


# --- Expected set -----------------------------------------------------------


def is_expected(cfg: dict, changed_files: list[str], base_ref: str) -> bool:
    """Would GitHub run a workflow with this pull_request config for this PR head?"""
    validate_constructs("pull_request", cfg)
    types = set(cfg.get("types", DEFAULT_TYPES))
    if types <= CLOSE_TYPES:
        return False  # types: [closed] -- never part of validating an open head
    if "branches" in cfg and select(cfg["branches"], base_ref) is not True:
        return False
    if "branches-ignore" in cfg and select(cfg["branches-ignore"], base_ref) is True:
        return False
    if "paths" in cfg:
        return any(select(cfg["paths"], f) is True for f in changed_files)
    if "paths-ignore" in cfg:
        return any(select(cfg["paths-ignore"], f) is not True for f in changed_files)
    return True


def expected_set(manifest: dict, changed_files: list[str], base_ref: str) -> list[tuple[str, str]]:
    """`(file, event)` pairs GitHub is expected to run for this PR, in manifest order."""
    out = []
    for filename, declared in (manifest.get("workflows") or {}).items():
        for event, cfg in normalize_on(declared if declared is not None else {}).items():
            if is_expected(cfg, changed_files, base_ref):
                out.append((filename, event))
    return out


def observed_unexpected(manifest: dict, runs: list[dict], expected: list[tuple[str, str]], own_run_id) -> list[tuple[str, str]]:
    """Manifest workflows that have a PR run on this head although their filters did not select it.

    GitHub runs every path-filtered workflow when it cannot compute the diff,
    so a run that exists is evidence the filters did not predict; it is
    aggregated rather than ignored, and its failure blocks like any other.
    """
    out = []
    for filename, declared in (manifest.get("workflows") or {}).items():
        for event, cfg in normalize_on(declared if declared is not None else {}).items():
            if set(cfg.get("types", DEFAULT_TYPES)) <= CLOSE_TYPES:
                continue  # a closed-only workflow's stale run on a reopened head is never evidence
            if (filename, event) not in expected and latest_run(runs, filename, event, own_run_id) is not None:
                out.append((filename, event))
    return out


# --- Aggregation ------------------------------------------------------------


def latest_run(runs: list[dict], filename: str, event: str, own_run_id) -> dict | None:
    """The newest run of `<file>` under `<event>` on the head SHA, never ci-gate's own."""
    path = f"{WORKFLOWS_DIR}/{filename}"
    candidates = [
        r for r in runs
        if r.get("path") == path
        and r.get("event") == event
        and str(r.get("id")) != str(own_run_id)
        and r.get("path") != f"{WORKFLOWS_DIR}/{SELF_WORKFLOW}"
    ]
    if not candidates:
        return None
    # A re-run updates the same run (new attempt, new run_started_at); a reopen
    # creates a new run. Newest start wins, id breaks ties.
    return max(candidates, key=lambda r: (r.get("run_started_at") or r.get("created_at") or "", int(r.get("id", 0))))


def aggregate(expected: list[tuple[str, str]], runs: list[dict], own_run_id) -> tuple[str, list[dict]]:
    """Return (`success`|`failure`|`pending`, rows) for the expected set."""
    rows = []
    verdict = "success"
    for filename, event in expected:
        run = latest_run(runs, filename, event, own_run_id)
        if run is None:
            state, detail = "pending", "no run yet"
        elif run.get("status") != "completed":
            state, detail = "pending", f"{run.get('status')} (run {run.get('id')})"
        elif run.get("conclusion") == "success":
            state, detail = "success", f"run {run.get('id')} attempt {run.get('run_attempt', 1)}"
        else:
            state, detail = "failure", f"{run.get('conclusion')} (run {run.get('id')} attempt {run.get('run_attempt', 1)})"
        rows.append({"workflow": filename, "event": event, "state": state, "detail": detail, "url": (run or {}).get("html_url")})
        if state == "failure":
            verdict = "failure"
        elif state == "pending" and verdict != "failure":
            verdict = "pending"
    return verdict, rows


# --- Settings lint ----------------------------------------------------------


def remote_keys(settings_text: str) -> list[str]:
    """Top-level `remote` / `remote.*` keys in a settings JSON document."""
    try:
        data = json.loads(settings_text)
    except ValueError as exc:
        raise GateError(f"not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        return []
    return sorted(k for k in data if k == "remote" or k.startswith("remote."))


def settings_paths_to_lint(changed_files: list[str]) -> list[str]:
    paths = {SETTINGS_FILE}
    for f in changed_files:
        if f == SETTINGS_FILE or f.endswith("/" + SETTINGS_FILE):
            paths.add(f)
    return sorted(paths)


# --- cloud-setup.sh lint ----------------------------------------------------

# A word boundary at the start of a shell command: line start, or a separator.
_CMD = r"(?:^|[\s;&|(`{])"
# ... optionally followed by a path, so /usr/bin/make is the same finding as
# make: the rule names the tool, not the spelling used to reach it.
_PATH = r"(?:(?:[\w.~+-]*/)+)?"
# ... and a boundary at the end: whitespace, end of line, or a closing separator.
_END = r"(?:\s|$|[;&|)`}])"
# (regex, what it is). Each is applied to a logical line with its comments
# removed. A screen for the invocations spec 2b names, not a sandbox: the rule
# itself is the header line the script must carry.
CLOUD_SETUP_FORBIDDEN = [
    (re.compile(_CMD + r"\.{1,2}/"), "a relative path (./ or ../)"),
    # `. file` in command position; `(. == x)` inside a jq program is not it.
    (re.compile(_CMD + r"(?:source\s+\S|\.\s+[^\s=!<>|&)])"), "sourcing a file"),
    (re.compile(_CMD + _PATH + r"make" + _END), "make"),
    (re.compile(_CMD + _PATH + r"(?:npm|npx|pnpm|yarn|bun)" + _END), "a Node package manager"),
    (re.compile(_CMD + _PATH + r"pip3?\s+install" + _END), "pip install"),
    (re.compile(_CMD + _PATH + r"(?:uv|uvx|poetry|pipenv)" + _END), "a Python project tool"),
    (re.compile(_CMD + _PATH + r"(?:cargo|gradle|gradlew|mvn|bundle|composer|mix|swift|go)\s+(?:build|run|install|test|sync|generate|mod|package|exec)" + _END), "a build tool"),
    (re.compile(_CMD + _PATH + r"(?:direnv|pre-commit|terraform|docker|docker-compose|xcodegen)" + _END), "a tool that reads project files"),
]

# Interpreters whose first non-option argument is a script, with the option
# letters that switch them to inline code (nothing from the checkout runs), the
# option letters that consume the following token, and the long forms of both.
_INTERPRETER = re.compile(_CMD + _PATH + r"(bash|sh|zsh|python3?|node|ruby|perl)(?=\s)")
_CODE_LETTERS = {"bash": "c", "sh": "c", "zsh": "c", "python": "cm", "python3": "cm", "node": "ep", "ruby": "e", "perl": "eE"}
_ARG_LETTERS = {"bash": "o", "sh": "o", "zsh": "o", "python": "WXQ", "python3": "WXQ", "node": "r", "ruby": "Ir", "perl": "IM"}
_LONG_CODE = {"node": {"--eval", "--print"}, "python": {"--command"}, "python3": {"--command"}}
# Long options that consume the following token. An option outside both maps is
# ambiguous -- `bash --rcfile /tmp/rc setup.sh` would otherwise read /tmp/rc as
# the script, accept it as absolute, and never see setup.sh -- so the lint says
# so rather than guessing.
_LONG_ARG = {"bash": {"--rcfile", "--init-file"}, "sh": set(), "zsh": {"--rcfile"},
             "node": {"--require", "--import"}, "python": set(), "python3": set(),
             "ruby": set(), "perl": set()}


def _strip_comment(line: str) -> str:
    """Drop a trailing `#` comment, honoring single and double quotes."""
    single = double = False
    i = 0
    while i < len(line):
        ch = line[i]
        if ch == "\\" and not single:
            i += 2
            continue
        if ch == "'" and not double:
            single = not single
        elif ch == '"' and not single:
            double = not double
        elif ch == "#" and not single and not double and (i == 0 or line[i - 1].isspace()):
            return line[:i]
        i += 1
    return line


def logical_lines(text: str) -> list[tuple[int, str]]:
    """(first line number, code) pairs: comments stripped, continuations joined.

    Comments come off each *physical* line first, because a shell comment ends
    at the newline however it ends -- `# note \\` does not continue. What is
    left is then joined across trailing backslashes, so `ma\\` + `ke`, which the
    shell runs as `make`, is one logical line the patterns below can see.
    """
    out: list[tuple[int, str]] = []
    buf, start = "", None
    for lineno, raw in enumerate(text.splitlines(), 1):
        code = _strip_comment(raw)
        if start is None:
            start = lineno
        if (len(code) - len(code.rstrip("\\"))) % 2 == 1:
            buf += code[:-1]
            continue
        out.append((start, buf + code))
        buf, start = "", None
    if start is not None:
        out.append((start, buf))
    return out


def interpreter_risk(line: str) -> str | None:
    """Why an interpreter on this line might run something from the checkout.

    Walks the interpreter's options so `bash -e setup.sh` and `python3 -O
    setup.py` are caught while `bash -euo pipefail -c "$s"` and `node -e x` are
    not. Only a literal absolute path is accepted as the script: a variable can
    hold a path back into the checkout (`bash "$CLAUDE_PROJECT_DIR/x.sh"`), and
    this lint cannot know what it holds. A long option in neither map is
    reported rather than assumed to take no argument.
    """
    for m in _INTERPRETER.finditer(line):
        interp = m.group(1)
        rest = re.split(r"[;|&)`]", line[m.end():], 1)[0]
        tokens = rest.split()
        script = None
        i = 0
        while i < len(tokens):
            tok = tokens[i]
            if tok == "--":
                script = tokens[i + 1] if i + 1 < len(tokens) else None
                break
            if tok.startswith("--"):
                if tok in _LONG_CODE.get(interp, ()):
                    break
                if tok in _LONG_ARG.get(interp, ()):
                    i += 2
                    continue
                return f"an interpreter given a long option this lint cannot interpret ({tok}), so its script argument is unknown"
            if tok.startswith("-") or (tok.startswith("+") and interp in ("bash", "sh", "zsh")):
                letters = tok[1:]
                if any(c in _CODE_LETTERS[interp] for c in letters):
                    break
                i += 2 if letters and letters[-1] in _ARG_LETTERS[interp] else 1
                continue
            script = tok
            break
        if script:
            script = script.strip("\"'")
            if script and not script.startswith("/"):
                return "an interpreter run on a script that is not a literal absolute path"
    return None


def cloud_setup_lint(text: str) -> list[str]:
    """Reasons `.claude/cloud-setup.sh` violates spec 2b's provisioning rule.

    The environment runs the origin/main copy of this script, and protecting
    the text is not enough on its own: the script must also execute nothing
    from the checkout, since a branch can plant a Makefile, a lockfile, or a
    postinstall hook. This lint requires the header that states that rule --
    as a comment line, not the phrase buried in a string -- and flags the
    invocations the spec names.
    """
    reasons = []
    if not re.search(r"^[ \t]*#.*" + re.escape(CLOUD_SETUP_HEADER), text, re.M):
        reasons.append(f"missing the header comment stating the rule ({CLOUD_SETUP_HEADER!r})")
    for lineno, line in logical_lines(text):
        what = next((name for pattern, name in CLOUD_SETUP_FORBIDDEN if pattern.search(line)), None)
        if what is None:
            what = interpreter_risk(line)
        if what:
            reasons.append(f"line {lineno}: {what}, which could execute something from the checkout: {line.strip()}")
    return reasons


# --- Evaluation over an API-shaped interface --------------------------------


class Api:
    """The GitHub REST calls the evaluator needs. Tests substitute a fake."""

    def __init__(self, repo: str, token: str, base_url: str):
        self.repo, self.token, self.base_url = repo, token, base_url.rstrip("/")

    def _request(self, path: str, params: dict | None = None, raw: bool = False):
        url = f"{self.base_url}/repos/{self.repo}/{path}"
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Accept", "application/vnd.github.raw+json" if raw else "application/vnd.github+json")
        req.add_header("X-GitHub-Api-Version", "2022-11-28")
        # A stalled connection must fail (and let the report job post
        # `failure`) rather than hold the runner until the job timeout.
        with urllib.request.urlopen(req, timeout=API_TIMEOUT_SECONDS) as resp:
            body = resp.read().decode()
            link = resp.headers.get("Link", "")
        return (body if raw else json.loads(body)), link

    def get(self, path: str, params: dict | None = None):
        return self._request(path, params)[0]

    def paginate(self, path: str, key: str | None = None, params: dict | None = None) -> list:
        params = dict(params or {}, per_page=100, page=1)
        items: list = []
        while True:
            page, link = self._request(path, params)
            items.extend(page[key] if key else page)
            if 'rel="next"' not in link:
                return items
            params["page"] += 1

    def raw(self, path: str, ref: str) -> str | None:
        try:
            return self._request(f"contents/{path}", {"ref": ref}, raw=True)[0]
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return None
            raise

    def listing(self, path: str, ref: str) -> list[dict]:
        try:
            return self.get(f"contents/{path}", {"ref": ref})
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return []
            raise

    def default_branch(self) -> str:
        return self.get("")["default_branch"]

    def open_prs(self, base: str) -> list[dict]:
        return self.paginate("pulls", params={"state": "open", "base": base})

    def pull(self, number: int) -> dict:
        return self.get(f"pulls/{number}")

    def changed_files(self, number: int) -> list[dict]:
        return self.paginate(f"pulls/{number}/files")

    def runs(self, head_sha: str) -> list[dict]:
        return self.paginate("actions/runs", key="workflow_runs", params={"head_sha": head_sha})


def resolve_pr(api: Api, head_sha: str) -> tuple[str, dict | None, list[str]]:
    """Pick the one open PR to `main` whose head is `head_sha`.

    Returns (`ok`|`skip`|`failure`, pr, reasons). `skip` means nothing to report.
    """
    candidates = [pr for pr in api.open_prs(PROTECTED_BASE) if pr["head"]["sha"] == head_sha]
    if not candidates:
        return "skip", None, [f"no open PR to {PROTECTED_BASE} has head {head_sha}"]
    if len(candidates) > 1:
        numbers = ", ".join(f"#{pr['number']}" for pr in candidates)
        return "failure", candidates[0], [f"head {head_sha} is shared by more than one open PR to {PROTECTED_BASE} ({numbers}); fail closed"]
    return "ok", candidates[0], []


def evaluate(api: Api, head_sha: str, own_run_id, base_sha: str | None = None) -> dict:
    """Full evaluation. Returns a result dict; `verdict` is success|failure|pending|skip.

    `base_sha` is the commit the running copy of ci-gate.yml comes from; when
    given, a pending workflow whose name that copy is not subscribed to is
    flagged, since its completion will not re-trigger this gate.
    """
    reasons: list[str] = []
    rows: list[dict] = []
    status, pr, why = resolve_pr(api, head_sha)
    if status == "skip":
        return {"verdict": "skip", "head_sha": head_sha, "reasons": why, "rows": rows}
    head_sha = pr["head"]["sha"]
    number = pr["number"]
    reasons += why

    default_branch = api.default_branch()
    if default_branch != PROTECTED_BASE:
        reasons.append(f"repository default branch is {default_branch!r}, not {PROTECTED_BASE!r}; ci-gate refuses to run")

    files = api.changed_files(number)
    changed = [f["filename"] for f in files]
    if len(changed) > MAX_CHANGED_FILES:
        reasons.append(f"{len(changed)} changed files: GitHub evaluates path filters on at most {MAX_CHANGED_FILES}, which ci-gate cannot mirror")
    commits = int(api.pull(number).get("commits") or 0)
    if commits > MAX_COMMITS:
        reasons.append(f"{commits} commits: GitHub skips path filtering (runs everything) above {MAX_COMMITS}, which ci-gate cannot mirror")

    # Head-tree manifest + workflows.
    workflows: dict[str, object] = {}
    for entry in api.listing(WORKFLOWS_DIR, head_sha):
        name = entry.get("name", "")
        if entry.get("type") == "file" and name.endswith((".yml", ".yaml")):
            text = api.raw(f"{WORKFLOWS_DIR}/{name}", head_sha) or ""
            try:
                workflows[name] = yaml.safe_load(text)
            except yaml.YAMLError as exc:
                reasons.append(f"{WORKFLOWS_DIR}/{name}: not valid YAML: {exc}")
                workflows[name] = {}
    manifest_text = api.raw(MANIFEST_PATH, head_sha)
    manifest = None
    if manifest_text is None:
        reasons.append(f"{MANIFEST_PATH} is missing from the head tree")
    else:
        try:
            manifest = yaml.safe_load(manifest_text)
        except yaml.YAMLError as exc:
            reasons.append(f"{MANIFEST_PATH}: not valid YAML: {exc}")
        else:
            # An empty or `null` file parses to None; lint reports it as not a
            # mapping rather than letting expected_set crash on it later.
            reasons += lint(manifest, workflows, workflows.get(SELF_WORKFLOW))

    # remote.* settings lint (spec 2c).
    for path in settings_paths_to_lint(changed):
        text = api.raw(path, head_sha)
        if text is None:
            continue
        try:
            keys = remote_keys(text)
        except GateError as exc:
            reasons.append(f"{path}: {exc}")
            continue
        if keys:
            reasons.append(f"{path}: carries {', '.join(keys)}; remote.* settings must not reach {PROTECTED_BASE}")

    # cloud-setup.sh lint (spec 2b): the provisioning script the environment
    # runs from origin/main, read from the head tree so a violation is caught
    # before it lands there.
    setup_text = api.raw(CLOUD_SETUP_FILE, head_sha)
    if setup_text is not None:
        reasons += [f"{CLOUD_SETUP_FILE}: {r}" for r in cloud_setup_lint(setup_text)]
    elif base_sha and api.raw(CLOUD_SETUP_FILE, base_sha) is not None:
        reasons.append(f"{CLOUD_SETUP_FILE}: removed by this PR; the factory environment provisions from {PROTECTED_BASE}'s copy, so it must stay in the tree")

    if reasons:
        return {"verdict": "failure", "head_sha": head_sha, "pr": number, "reasons": reasons, "rows": rows, "changed_files": len(changed)}

    runs = api.runs(head_sha)
    expected = expected_set(manifest, changed, pr["base"]["ref"])
    observed = observed_unexpected(manifest, runs, expected, own_run_id)
    verdict, rows = aggregate(expected + observed, runs, own_run_id)
    for row in rows:
        if (row["workflow"], row["event"]) in observed:
            row["detail"] += "; ran although its filters did not select this PR (GitHub diff fallback?), so it counts"
    if base_sha:
        flag_unsubscribed(rows, workflows, subscribed_names(api, base_sha))
    return {"verdict": verdict, "head_sha": head_sha, "pr": number, "reasons": reasons, "rows": rows,
            "changed_files": len(changed), "notes": ci_change_notes(changed)}


def ci_change_notes(changed_files: list[str]) -> list[str]:
    """Call out a PR that edits the inputs the expected set is computed from.

    The manifest and workflows are read from the PR head (see the module
    docstring), so a PR can narrow its own CI; the lint guarantees such a
    change always shows in the manifest diff, and this note puts it in the
    check output where the reviewer looks. It is information for the human
    review that covers every non-docs class, not a verdict.
    """
    touched = sorted(f for f in changed_files if f == MANIFEST_PATH or f.startswith(WORKFLOWS_DIR + "/"))
    if not touched:
        return []
    return ["This PR changes CI configuration; the expected set above is computed from the PR's own copy of it, "
            "so review these files for removed or narrowed triggers: " + ", ".join(f"`{f}`" for f in touched)]


def subscribed_names(api: Api, base_sha: str) -> list[str] | None:
    """The `workflow_run.workflows` names in the copy of ci-gate.yml at `base_sha`."""
    text = api.raw(f"{WORKFLOWS_DIR}/{SELF_WORKFLOW}", base_sha)
    if text is None:
        return None
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError:
        return None
    raw_on = doc.get("on", doc.get(True)) if isinstance(doc, dict) else None
    names = ((raw_on or {}).get("workflow_run") or {}).get("workflows") if isinstance(raw_on, dict) else None
    return [names] if isinstance(names, str) else list(names or [])


def flag_unsubscribed(rows: list[dict], workflows: dict[str, object], subscribed: list[str] | None) -> None:
    """Mark pending rows whose completion the running ci-gate will never hear about.

    `workflow_run` matches by workflow *name*, so a PR that adds or renames a
    workflow is re-evaluated by `main`'s copy of ci-gate.yml, which still
    subscribes to the old list; the head lint cannot fix that. Say so in the
    row rather than leave the gate silently pending.
    """
    if subscribed is None:
        return
    for row in rows:
        name = workflow_name(row["workflow"], workflows.get(row["workflow"]))
        if row["state"] == "pending" and name not in subscribed:
            row["detail"] += (
                f"; the running ci-gate is not subscribed to {name!r} (added or renamed on this branch), "
                "so its completion will not re-evaluate this PR: re-run ci-gate or dispatch it with this head SHA"
            )


# --- Rendering + Actions glue -----------------------------------------------


def render(result: dict) -> tuple[str, str]:
    """(title, markdown summary) for the check run and the step summary."""
    verdict = result["verdict"]
    lines = []
    if result.get("pr"):
        lines.append(f"PR #{result['pr']} at `{result['head_sha']}` — {result.get('changed_files', 0)} changed file(s).")
    if result["reasons"]:
        lines.append("")
        lines += [f"- {r}" for r in result["reasons"]]
    if result["rows"]:
        lines += ["", "| Workflow | Event | State | Detail |", "|---|---|---|---|"]
        for row in result["rows"]:
            detail = row["detail"]
            if row.get("url"):
                detail = f"[{detail}]({row['url']})"
            lines.append(f"| `{row['workflow']}` | `{row['event']}` | {row['state']} | {detail} |")
    elif verdict == "success":
        lines += ["", "No CI workflow is expected for these files; nothing to wait for."]
    for note in result.get("notes") or []:
        lines += ["", f"⚠ {note}"]
    titles = {
        "success": "All expected CI workflows succeeded",
        "failure": "Blocked",
        "pending": "Waiting for expected CI workflows",
        "skip": "Nothing to evaluate",
    }
    return titles[verdict], "\n".join(lines).strip() + "\n"


VERDICTS = ("success", "failure", "pending", "skip")


def output_lines(result: dict, title: str, summary: str) -> list[tuple[str, str]]:
    """The `key=value` pairs handed to the privileged report job, one line each.

    PR-controlled text (manifest keys, workflow names, filter patterns) reaches
    the summary verbatim, so it never crosses the job boundary as raw lines: a
    multiline `<<DELIM` block would let content containing the delimiter smuggle
    in extra outputs such as `verdict=`. The title and summary travel as one
    JSON-encoded ASCII line each (json.dumps escapes every newline and non-ASCII
    character), and the report job decodes them; the scalar outputs are
    validated against fixed grammars before they are written.
    """
    verdict = result["verdict"]
    if verdict not in VERDICTS:
        raise GateError(f"invalid verdict {verdict!r}")
    head_sha = result.get("head_sha") or ""
    if head_sha and not re.fullmatch(r"[0-9a-f]{40}", head_sha):
        raise GateError(f"invalid head SHA {head_sha!r}")
    pr = str(result.get("pr") or "")
    if pr and not pr.isdigit():
        raise GateError(f"invalid PR number {pr!r}")
    lines = [
        ("verdict", verdict),
        ("head_sha", head_sha),
        ("pr", pr),
        ("title_json", json.dumps(title)),
        ("summary_json", json.dumps(summary)),
    ]
    for key, value in lines:
        assert "\n" not in value and "\r" not in value, key
    return lines


def write_outputs(result: dict, title: str, summary: str) -> None:
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write("".join(f"{k}={v}\n" for k, v in output_lines(result, title, summary)))
    step = os.environ.get("GITHUB_STEP_SUMMARY")
    if step:
        with open(step, "a") as fh:
            fh.write(f"## {CHECK_NAME}: {result['verdict']} — {title}\n\n{summary}")


def dispatch_head_sha(event: dict) -> str:
    """The `head_sha` input of a workflow_dispatch event, validated as a canonical full SHA.

    Canonical (lowercase, no surrounding whitespace) on purpose: the workflow's
    concurrency group is keyed on the raw input, so a normalized-but-different
    spelling would evaluate outside the group serializing that head.
    """
    value = str((event.get("inputs") or {}).get("head_sha", ""))
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise GateError(f"workflow_dispatch input head_sha must be a lowercase 40-hex commit SHA, got {value!r}")
    return value


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ.get("GH_TOKEN") or os.environ["GITHUB_TOKEN"]
    api = Api(repo, token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    with open(os.environ["GITHUB_EVENT_PATH"]) as fh:
        event = json.load(fh)

    if event_name == "pull_request_target":
        head_sha = event["pull_request"]["head"]["sha"]
    elif event_name == "workflow_run":
        head_sha = event["workflow_run"]["head_sha"]
    elif event_name == "workflow_dispatch":
        head_sha = dispatch_head_sha(event)
    else:
        print(f"ci-gate: unsupported event {event_name!r}", file=sys.stderr)
        return 1

    result = evaluate(api, head_sha, os.environ.get("GITHUB_RUN_ID"), os.environ.get("GITHUB_SHA"))
    title, summary = render(result)
    print(f"{CHECK_NAME}: {result['verdict']} — {title}\n\n{summary}")
    write_outputs(result, title, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
