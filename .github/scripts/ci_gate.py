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
   entry for ci-gate itself, a listed workflow whose actual `on:` differs, an
   unlisted PR-triggered workflow, a trigger construct this evaluator does not
   implement, or a `workflow_run.workflows` list in ci-gate.yml that does not
   match the manifest all fail the gate). The head tree is used because it is
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
   subdirectory) carries a `remote.*` key (spec section 2c).

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
PR_EVENTS = ("pull_request", "pull_request_target")
SUPPORTED_KEYS = {"types", "branches", "branches-ignore", "paths", "paths-ignore"}
DEFAULT_TYPES = ["opened", "synchronize", "reopened"]
HEAD_TYPES = {"opened", "synchronize"}
# GitHub evaluates path filters against at most 300 changed files.
MAX_CHANGED_FILES = 300
SETTINGS_FILE = ".claude/settings.json"


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
            if pattern.startswith("**", i):
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
    if cfg is None:
        return {}
    if not isinstance(cfg, dict):
        raise GateError(f"{event}: trigger config must be a mapping, got {cfg!r}")
    if event not in PR_EVENTS:
        # Non-PR triggers never decide whether a workflow runs on a PR; their
        # content is irrelevant to the gate and is neither compared nor validated.
        return {}
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
            declared_norm = normalize_on(declared if declared is not None else {})
            if set(declared_norm) - set(PR_EVENTS):
                raise GateError("manifest entries may only declare pull_request / pull_request_target")
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
        try:
            workflow_on(gate_doc)  # parse errors surface here
            raw_gate = gate_doc.get("on", gate_doc.get(True)) or {}
            names = (raw_gate.get("workflow_run") or {}).get("workflows") if isinstance(raw_gate, dict) else None
            names = [names] if isinstance(names, str) else list(names or [])
            expected_names = sorted(workflow_name(f, workflows[f]) for f in entries if f in workflows)
            if sorted(names) != expected_names:
                errors.append(
                    f"{SELF_WORKFLOW}: on.workflow_run.workflows must list exactly the manifest's workflows\n"
                    f"      ci-gate:  {sorted(names)}\n"
                    f"      manifest: {expected_names}"
                )
        except GateError as exc:
            errors.append(f"{SELF_WORKFLOW}: {exc}")
    return errors


def validate_constructs(event: str, cfg: dict) -> None:
    """Reject trigger configs whose GitHub behaviour this evaluator cannot mirror."""
    types = set(cfg.get("types", DEFAULT_TYPES))
    if types & HEAD_TYPES and not HEAD_TYPES <= types:
        raise GateError(
            f"{event}.types {sorted(types)}: must include both opened and synchronize "
            "(or neither) for ci-gate to know whether a head SHA triggers it"
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
    if not HEAD_TYPES <= types:
        return False  # e.g. types: [closed] -- never runs when a head SHA appears
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
        with urllib.request.urlopen(req) as resp:
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


def resolve_pr(api: Api, head_sha: str | None, pr_number: int | None) -> tuple[str, dict | None, list[str]]:
    """Pick the one open PR to `main` for this evaluation.

    Returns (`ok`|`skip`|`failure`, pr, reasons). `skip` means nothing to report.
    """
    if pr_number is not None:
        pr = api.pull(pr_number)
        if pr.get("state") != "open":
            return "skip", None, [f"PR #{pr_number} is not open"]
        if pr["base"]["ref"] != PROTECTED_BASE:
            return "skip", None, [f"PR #{pr_number} targets {pr['base']['ref']}, not {PROTECTED_BASE}"]
        head_sha = pr["head"]["sha"]
    candidates = [pr for pr in api.open_prs(PROTECTED_BASE) if pr["head"]["sha"] == head_sha]
    if not candidates:
        return "skip", None, [f"no open PR to {PROTECTED_BASE} has head {head_sha}"]
    if len(candidates) > 1:
        numbers = ", ".join(f"#{pr['number']}" for pr in candidates)
        return "failure", candidates[0], [f"head {head_sha} is shared by more than one open PR to {PROTECTED_BASE} ({numbers}); fail closed"]
    return "ok", candidates[0], []


def evaluate(api: Api, head_sha: str | None, pr_number: int | None, own_run_id) -> dict:
    """Full evaluation. Returns a result dict; `verdict` is success|failure|pending|skip."""
    reasons: list[str] = []
    rows: list[dict] = []
    status, pr, why = resolve_pr(api, head_sha, pr_number)
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
    if manifest is not None:
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

    if reasons:
        return {"verdict": "failure", "head_sha": head_sha, "pr": number, "reasons": reasons, "rows": rows, "changed_files": len(changed)}

    expected = expected_set(manifest, changed, pr["base"]["ref"])
    verdict, rows = aggregate(expected, api.runs(head_sha), own_run_id)
    return {"verdict": verdict, "head_sha": head_sha, "pr": number, "reasons": reasons, "rows": rows, "changed_files": len(changed)}


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


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    token = os.environ.get("GH_TOKEN") or os.environ["GITHUB_TOKEN"]
    api = Api(repo, token, os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    event_name = os.environ.get("GITHUB_EVENT_NAME", "")
    with open(os.environ["GITHUB_EVENT_PATH"]) as fh:
        event = json.load(fh)

    head_sha = pr_number = None
    if event_name == "pull_request_target":
        head_sha = event["pull_request"]["head"]["sha"]
    elif event_name == "workflow_run":
        head_sha = event["workflow_run"]["head_sha"]
    elif event_name == "workflow_dispatch":
        pr_number = int(event["inputs"]["pr"])
    else:
        print(f"ci-gate: unsupported event {event_name!r}", file=sys.stderr)
        return 1

    result = evaluate(api, head_sha, pr_number, os.environ.get("GITHUB_RUN_ID"))
    title, summary = render(result)
    print(f"{CHECK_NAME}: {result['verdict']} — {title}\n\n{summary}")
    write_outputs(result, title, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
