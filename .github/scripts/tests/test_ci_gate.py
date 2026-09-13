"""Unit tests for .github/scripts/ci_gate.py (spec section 1d).

Pure-function tests for the filter semantics, the manifest lint, the expected
set, and the aggregation; an evaluation test over a fake API; and a self-check
that this repository's own manifest, workflows, and ci-gate.yml agree.
"""
import copy
import json
import os
import sys

import pytest
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

import ci_gate  # noqa: E402


def wf(on, name=None):
    doc = {"jobs": {"x": {"runs-on": "ubuntu-latest", "steps": []}}}
    if name:
        doc["name"] = name
    doc["on"] = on
    return doc


def gate(names, **overrides):
    on = {"pull_request_target": {"types": ["opened", "synchronize", "reopened", "ready_for_review", "edited"], "branches": ["main"]},
          "workflow_run": {"workflows": names, "types": ["completed"]},
          "workflow_dispatch": {"inputs": {"head_sha": {"required": True, "type": "string"}}}}
    on.update(overrides)
    return wf(on, "ci-gate")


GM = {"pull_request": {"paths": ["plugins/gm/**", ".github/workflows/gm-ci.yml"]}}
MANIFEST = {"schema": "factory-ci/1", "workflows": {"gm-ci.yml": GM, "plugin-versions.yml": {"pull_request": {}}}}
WORKFLOWS = {
    "gm-ci.yml": wf({"push": {"paths": ["plugins/gm/**"]}, **GM}, "gm CI"),
    "plugin-versions.yml": wf({"pull_request": None}, "plugin versions"),
    "ci-gate.yml": gate(["gm CI", "plugin versions"]),
}


# --- filter patterns ---------------------------------------------------------

@pytest.mark.parametrize("pattern,value,expected", [
    ("plugins/gm/**", "plugins/gm/a/b.py", True),
    ("plugins/gm/**", "plugins/gmx/a.py", False),
    ("plugins/*/README.md", "plugins/gm/README.md", True),
    ("plugins/*/README.md", "plugins/gm/sub/README.md", False),  # * does not cross /
    ("**.md", "docs/a/b.md", True),
    ("**.md", "docs/a/b.py", False),
    ("docs/*", "docs/a.md", True),
    ("docs/*", "docs/a/b.md", False),
    ("main", "main", True),
    ("releases/**", "releases/v1/x", True),
    ("v[0-9]+", "v12", True),
    ("v[0-9]+", "vx", False),
    ("READ?ME", "REAME", True),  # ? = zero or one of the preceding character
    ("**/package.json", "package.json", True),  # **/ = zero or more directories
    ("**/package.json", "a/b/package.json", True),
    ("**/package.json", "apackage.json", False),
    ("src/**/x.py", "src/x.py", True),
    ("a.b", "axb", False),  # literal dot
    ("src/\\!important.js", "src/!important.js", True),  # backslash escapes the next character
    ("docs/\\*", "docs/*", True),
    ("docs/\\*", "docs/a", False),
    ("a\\[b]", "a[b]", True),
    ("v[!0-9]", "vx", True),  # [!...] is a negated class
    ("v[!0-9]", "v1", False),
])
def test_pattern(pattern, value, expected):
    assert bool(ci_gate.pattern_to_regex(pattern).match(value)) is expected


def test_select_last_match_wins():
    assert ci_gate.select(["docs/**", "!docs/keep.md"], "docs/keep.md") is False
    assert ci_gate.select(["docs/**", "!docs/keep.md", "docs/keep.md"], "docs/keep.md") is True
    assert ci_gate.select(["docs/**"], "src/x") is None


# --- normalization -----------------------------------------------------------

def test_on_forms_normalize_equally():
    assert ci_gate.normalize_on("pull_request") == {"pull_request": {}}
    assert ci_gate.normalize_on(["pull_request", "push"]) == {"pull_request": {}, "push": {}}
    assert ci_gate.normalize_on({"pull_request": None}) == {"pull_request": {}}
    assert ci_gate.normalize_on({"pull_request": {"paths": "a/**"}}) == {"pull_request": {"paths": ["a/**"]}}


def test_bare_on_key_parses_as_true():
    doc = yaml.safe_load("on:\n  pull_request:\n    paths: ['a/**']\n")
    assert ci_gate.workflow_on(doc) == {"pull_request": {"paths": ["a/**"]}}


def test_unknown_construct_rejected():
    with pytest.raises(ci_gate.GateError):
        ci_gate.normalize_on({"pull_request": {"tags": ["v*"]}})


# --- lint --------------------------------------------------------------------

def test_lint_consistent():
    assert ci_gate.lint(MANIFEST, WORKFLOWS, WORKFLOWS["ci-gate.yml"]) == []


def test_lint_rejects_self_entry():
    m = copy.deepcopy(MANIFEST)
    m["workflows"]["ci-gate.yml"] = {"pull_request_target": {}}
    errors = ci_gate.lint(m, WORKFLOWS, WORKFLOWS["ci-gate.yml"])
    assert any("must not list itself" in e for e in errors)


def test_lint_detects_drift():
    w = copy.deepcopy(WORKFLOWS)
    w["gm-ci.yml"]["on"]["pull_request"]["paths"].append("extra/**")
    errors = ci_gate.lint(MANIFEST, w, w["ci-gate.yml"])
    assert any("gm-ci.yml: manifest entry differs" in e for e in errors)


def test_lint_ignores_non_pr_triggers():
    w = copy.deepcopy(WORKFLOWS)
    w["gm-ci.yml"]["on"]["push"] = {"branches": ["main"], "tags": ["v*"]}
    w["gm-ci.yml"]["on"]["workflow_dispatch"] = None
    w["gm-ci.yml"]["on"]["schedule"] = [{"cron": "0 3 * * 1"}]  # a list, not a mapping
    assert ci_gate.lint(MANIFEST, w, w["ci-gate.yml"]) == []
    assert ci_gate.normalize_on({"schedule": [{"cron": "0 3 * * 1"}], "pull_request": None}) == {"schedule": {}, "pull_request": {}}


def test_lint_unlisted_pr_workflow():
    w = dict(WORKFLOWS, **{"new.yml": wf({"pull_request": {}}, "new")})
    errors = ci_gate.lint(MANIFEST, w, w["ci-gate.yml"])
    assert any("new.yml: has a pull_request trigger but is not listed" in e for e in errors)


def test_lint_missing_listed_workflow():
    w = {k: v for k, v in WORKFLOWS.items() if k != "gm-ci.yml"}
    w["ci-gate.yml"] = gate(["plugin versions"])
    errors = ci_gate.lint(MANIFEST, w, w["ci-gate.yml"])
    assert any("gm-ci.yml is listed but" in e for e in errors)


def test_lint_workflow_without_pr_trigger_listed():
    m = copy.deepcopy(MANIFEST)
    m["workflows"]["deploy.yml"] = {"pull_request": {}}
    w = dict(WORKFLOWS, **{"deploy.yml": wf({"workflow_call": None}, "deploy")})
    errors = ci_gate.lint(m, w, w["ci-gate.yml"])
    assert any("deploy.yml: manifest entry differs" in e or "no pull_request trigger" in e for e in errors)


def test_lint_workflow_run_list_must_match():
    w = dict(WORKFLOWS, **{"ci-gate.yml": gate(["gm CI"])})
    errors = ci_gate.lint(MANIFEST, w, w["ci-gate.yml"])
    assert any("workflow_run.workflows must list exactly" in e for e in errors)


def test_lint_gate_trigger_shape():
    cases = {
        "drop target": gate(["gm CI", "plugin versions"], pull_request_target=None),
        "narrow types": gate(["gm CI", "plugin versions"], pull_request_target={"types": ["opened"], "branches": ["main"]}),
        "wrong branch": gate(["gm CI", "plugin versions"], pull_request_target={"types": ["opened", "synchronize", "reopened"], "branches": ["dev"]}),
        "run types": gate(["gm CI", "plugin versions"], workflow_run={"workflows": ["gm CI", "plugin versions"], "types": ["requested"]}),
        "no dispatch": gate(["gm CI", "plugin versions"], workflow_dispatch=None),
        "bare dispatch": gate(["gm CI", "plugin versions"], workflow_dispatch=None),
        "optional head_sha": gate(["gm CI", "plugin versions"], workflow_dispatch={"inputs": {"head_sha": {"required": False, "type": "string"}}}),
        "renamed input": gate(["gm CI", "plugin versions"], workflow_dispatch={"inputs": {"pr": {"required": True, "type": "string"}}}),
        "target paths": gate(["gm CI", "plugin versions"], pull_request_target={"types": ["opened", "synchronize", "reopened"], "branches": ["main"], "paths": ["docs/**"]}),
        "target paths-ignore": gate(["gm CI", "plugin versions"], pull_request_target={"types": ["opened", "synchronize", "reopened"], "branches": ["main"], "paths-ignore": ["docs/**"]}),
        "run branches": gate(["gm CI", "plugin versions"], workflow_run={"workflows": ["gm CI", "plugin versions"], "types": ["completed"], "branches": ["main"]}),
        "extra pull_request event": gate(["gm CI", "plugin versions"], pull_request={"branches": ["main"]}),
        "extra push event": gate(["gm CI", "plugin versions"], push=None),
        "boolean head_sha": gate(["gm CI", "plugin versions"], workflow_dispatch={"inputs": {"head_sha": {"required": True, "type": "boolean"}}}),
        "no subscription list": gate(["gm CI", "plugin versions"], workflow_run={"types": ["completed"]}),
    }
    for label, doc in cases.items():
        if label == "no dispatch":
            del doc["on"]["workflow_dispatch"]
        errors = ci_gate.lint(MANIFEST, dict(WORKFLOWS, **{"ci-gate.yml": doc}), doc)
        assert errors and all(e.startswith("ci-gate.yml: on.") for e in errors), (label, errors)
    assert ci_gate.lint(MANIFEST, WORKFLOWS, WORKFLOWS["ci-gate.yml"]) == []


def test_lint_rejects_pull_request_target_entries():
    m = copy.deepcopy(MANIFEST)
    m["workflows"]["critic.yml"] = {"pull_request_target": {"branches": ["main"]}}
    w = dict(WORKFLOWS, **{"critic.yml": wf({"pull_request_target": {"branches": ["main"]}}, "critic")})
    errors = ci_gate.lint(m, w, w["ci-gate.yml"])
    assert any("critic.yml: manifest entries may only declare pull_request" in e for e in errors)
    # Unlisted, it is simply not aggregated -- never an "unlisted" error.
    assert ci_gate.lint(MANIFEST, w, w["ci-gate.yml"]) == []


def test_lint_rejects_empty_manifest():
    """An empty manifest would leave workflow_run without a real subscription list."""
    w = dict(WORKFLOWS, **{"ci-gate.yml": gate([])})
    w = {k: v for k, v in w.items() if k == "ci-gate.yml"}
    errors = ci_gate.lint({"schema": "factory-ci/1", "workflows": {}}, w, w["ci-gate.yml"])
    assert any("must list at least one" in e for e in errors)


def test_escaped_negation_is_literal():
    assert ci_gate.select(["src/\\!important.js"], "src/!important.js") is True
    assert ci_gate.is_expected({"paths": ["src/\\!x"]}, ["src/!x"], "main") is True


def test_failure_path_keeps_ci_change_note():
    tree = {k: v for k, v in TREE.items() if k != ".github/factory-ci.yml"}
    api = FakeApi([pr(1, "abc")], [".github/factory-ci.yml"], tree, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "failure" and result["notes"]
    _, summary = ci_gate.render(result)
    assert "⚠ This PR changes CI configuration" in summary


def test_evaluate_empty_manifest_fails_deterministically():
    tree = dict(TREE, **{".github/factory-ci.yml": ""})
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], tree, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "failure" and any("not a mapping" in r for r in result["reasons"])


def test_lint_missing_gate_file():
    errors = ci_gate.lint(MANIFEST, WORKFLOWS, None)
    assert any("ci-gate.yml is missing" in e for e in errors)


def test_lint_wrong_schema():
    m = dict(MANIFEST, schema="factory-ci/2")
    assert any("schema must be" in e for e in ci_gate.lint(m, WORKFLOWS, WORKFLOWS["ci-gate.yml"]))


def test_lint_requires_workflow_name():
    w = copy.deepcopy(WORKFLOWS)
    del w["plugin-versions.yml"]["name"]
    w["ci-gate.yml"] = gate(["gm CI", ".github/workflows/plugin-versions.yml"])
    errors = ci_gate.lint(MANIFEST, w, w["ci-gate.yml"])
    assert any("plugin-versions.yml: workflow has no `name:`" in e for e in errors)


def test_empty_types_rejected():
    with pytest.raises(ci_gate.GateError):
        ci_gate.is_expected({"types": []}, ["a"], "main")


def test_lint_rejects_event_only_types():
    m = copy.deepcopy(MANIFEST)
    m["workflows"]["plugin-versions.yml"] = {"pull_request": {"types": ["labeled"]}}
    w = copy.deepcopy(WORKFLOWS)
    w["plugin-versions.yml"]["on"] = {"pull_request": {"types": ["labeled"]}}
    errors = ci_gate.lint(m, w, w["ci-gate.yml"])
    assert any("must include both opened and synchronize" in e for e in errors)
    with pytest.raises(ci_gate.GateError):
        ci_gate.is_expected({"types": ["reopened"]}, ["a"], "main")


def test_lint_unsupported_types_split():
    m = copy.deepcopy(MANIFEST)
    m["workflows"]["plugin-versions.yml"] = {"pull_request": {"types": ["opened"]}}
    w = copy.deepcopy(WORKFLOWS)
    w["plugin-versions.yml"]["on"] = {"pull_request": {"types": ["opened"]}}
    errors = ci_gate.lint(m, w, w["ci-gate.yml"])
    assert any("must include both opened and synchronize" in e for e in errors)


# --- expected set ------------------------------------------------------------

def test_expected_docs_only_pr_expects_only_unfiltered():
    assert ci_gate.expected_set(MANIFEST, ["docs/guide.md"], "main") == [("plugin-versions.yml", "pull_request")]


def test_expected_gm_change_expects_gm_ci():
    assert ci_gate.expected_set(MANIFEST, ["plugins/gm/bin/roll"], "main") == [
        ("gm-ci.yml", "pull_request"), ("plugin-versions.yml", "pull_request")]


def test_expected_closed_only_types_never_expected():
    cfg = {"types": ["closed"], "paths": ["**"]}
    assert ci_gate.is_expected(cfg, ["a"], "main") is False


def test_expected_branch_filters():
    assert ci_gate.is_expected({"branches": ["dev"]}, ["a"], "main") is False
    assert ci_gate.is_expected({"branches": ["main"]}, ["a"], "main") is True
    assert ci_gate.is_expected({"branches-ignore": ["main"]}, ["a"], "main") is False


def test_expected_paths_ignore():
    cfg = {"paths-ignore": ["docs/**"]}
    assert ci_gate.is_expected(cfg, ["docs/a.md"], "main") is False
    assert ci_gate.is_expected(cfg, ["docs/a.md", "src/x.py"], "main") is True


def test_expected_paths_with_negation():
    cfg = {"paths": ["src/**", "!src/README.md"]}
    assert ci_gate.is_expected(cfg, ["src/README.md"], "main") is False
    assert ci_gate.is_expected(cfg, ["src/a.py"], "main") is True


def test_negative_only_filters_rejected():
    for cfg in ({"paths": ["!docs/**"]}, {"paths-ignore": ["!docs/**"]}, {"branches": ["!dev"]}):
        with pytest.raises(ci_gate.GateError):
            ci_gate.is_expected(cfg, ["a"], "main")
    assert ci_gate.is_expected({"paths": ["src/**", "!src/README.md"]}, ["src/a.py"], "main") is True


def test_expected_empty_diff_skips_filtered_workflows():
    assert ci_gate.is_expected({"paths": ["**"]}, [], "main") is False
    assert ci_gate.is_expected({}, [], "main") is True


# --- aggregation -------------------------------------------------------------

def run(path, event="pull_request", status="completed", conclusion="success", id=1, started="2026-01-01T00:00:00Z", attempt=1):
    return {"id": id, "path": f".github/workflows/{path}", "event": event, "status": status,
            "conclusion": conclusion, "run_started_at": started, "run_attempt": attempt, "html_url": f"https://x/{id}"}


EXPECTED = [("gm-ci.yml", "pull_request"), ("plugin-versions.yml", "pull_request")]


def test_aggregate_all_green():
    verdict, rows = ci_gate.aggregate(EXPECTED, [run("gm-ci.yml", id=1), run("plugin-versions.yml", id=2)], "999")
    assert verdict == "success" and [r["state"] for r in rows] == ["success", "success"]


def test_aggregate_missing_run_pending():
    verdict, rows = ci_gate.aggregate(EXPECTED, [run("plugin-versions.yml")], "999")
    assert verdict == "pending" and rows[0]["detail"] == "no run yet"


def test_aggregate_in_progress_pending():
    verdict, _ = ci_gate.aggregate(EXPECTED, [run("gm-ci.yml", status="in_progress", conclusion=None), run("plugin-versions.yml", id=2)], "999")
    assert verdict == "pending"


def test_aggregate_failure_beats_pending():
    verdict, _ = ci_gate.aggregate(EXPECTED, [run("gm-ci.yml", conclusion="failure")], "999")
    assert verdict == "failure"


@pytest.mark.parametrize("conclusion", ["failure", "cancelled", "timed_out", "skipped", "neutral", "action_required"])
def test_aggregate_only_success_counts(conclusion):
    verdict, _ = ci_gate.aggregate([("plugin-versions.yml", "pull_request")], [run("plugin-versions.yml", conclusion=conclusion)], "999")
    assert verdict == "failure"


def test_aggregate_latest_attempt_wins():
    # A re-run of the same run id turns an older red attempt green.
    runs = [run("plugin-versions.yml", id=5, conclusion="success", started="2026-01-02T00:00:00Z", attempt=2)]
    verdict, rows = ci_gate.aggregate([("plugin-versions.yml", "pull_request")], runs, "999")
    assert verdict == "success" and "attempt 2" in rows[0]["detail"]
    # A newer run (reopen) supersedes an older green one.
    runs = [run("plugin-versions.yml", id=5, started="2026-01-01T00:00:00Z"),
            run("plugin-versions.yml", id=7, conclusion="failure", started="2026-01-03T00:00:00Z")]
    verdict, _ = ci_gate.aggregate([("plugin-versions.yml", "pull_request")], runs, "999")
    assert verdict == "failure"


def test_aggregate_ignores_push_and_own_runs():
    runs = [run("plugin-versions.yml", event="push", id=1),
            run("plugin-versions.yml", id=2, status="in_progress", conclusion=None),
            run("ci-gate.yml", event="pull_request_target", id=3)]
    verdict, rows = ci_gate.aggregate([("plugin-versions.yml", "pull_request")], runs, "3")
    assert verdict == "pending"
    assert ci_gate.latest_run(runs, "ci-gate.yml", "pull_request_target", "3") is None
    assert ci_gate.latest_run(runs, "ci-gate.yml", "pull_request_target", "999") is None  # never expected, even as another run


def test_aggregate_run_must_belong_to_this_pr():
    """A closed PR's run on the same head does not satisfy (or block) a new PR."""
    old = dict(run("plugin-versions.yml", id=1), pull_requests=[{"number": 1}])
    assert ci_gate.latest_run([old], "plugin-versions.yml", "pull_request", "999", pr_number=2) is None
    assert ci_gate.latest_run([old], "plugin-versions.yml", "pull_request", "999", pr_number=1) is old
    fork = dict(run("plugin-versions.yml", id=3), pull_requests=[])  # fork runs list no PR
    assert ci_gate.latest_run([fork], "plugin-versions.yml", "pull_request", "999", pr_number=2) is fork
    verdict, rows = ci_gate.aggregate([("plugin-versions.yml", "pull_request")], [old], "999", pr_number=2)
    assert verdict == "pending" and rows[0]["detail"] == "no run yet"


def test_aggregate_nothing_expected_is_success():
    assert ci_gate.aggregate([], [], "1") == ("success", [])


# --- settings lint -----------------------------------------------------------

def test_remote_keys():
    assert ci_gate.remote_keys('{"remote": {"defaultEnvironmentId": "env_x"}}') == ["remote"]
    assert ci_gate.remote_keys('{"remote.defaultEnvironmentId": "env_x"}') == ["remote.defaultEnvironmentId"]
    assert ci_gate.remote_keys('{"permissions": {}}') == []
    with pytest.raises(ci_gate.GateError):
        ci_gate.remote_keys("{not json")


def test_settings_paths_to_lint():
    assert ci_gate.settings_paths_to_lint(["a.md", "svc/x/.claude/settings.json", "docs/settings.json"]) == [
        ".claude/settings.json", "svc/x/.claude/settings.json"]


# --- evaluation over a fake API ---------------------------------------------

class FakeApi:
    def __init__(self, prs, files, tree, runs, default="main", base_tree=None, commits=1):
        self.prs, self.files, self.tree, self._runs, self.default = prs, files, tree, runs, default
        self.base_tree = tree if base_tree is None else base_tree
        self.commits = commits

    def pull(self, number):
        return dict(next(p for p in self.prs if p["number"] == number), commits=self.commits)

    def default_branch(self):
        return self.default

    def open_prs(self, base):
        return [p for p in self.prs if p["state"] == "open" and p["base"]["ref"] == base]

    def changed_files(self, number):
        return [{"filename": f} for f in self.files]

    def raw(self, path, ref):
        return self._tree_for(ref).get(path)

    def _tree_for(self, ref):
        if ref == "base":
            return self.base_tree
        if getattr(self, "pull_ref_only", False):
            return self.tree if ref.startswith("refs/pull/") else {}
        return self.tree

    def listing(self, path, ref):
        tree = self._tree_for(ref)
        return [{"name": p.split("/")[-1], "type": "file"} for p in tree if p.startswith(path + "/") and p.count("/") == path.count("/") + 1]

    def runs(self, head_sha):
        return self._runs


def pr(number, sha, base="main", state="open"):
    return {"number": number, "state": state, "head": {"sha": sha}, "base": {"ref": base}}


TREE = {
    ".github/factory-ci.yml": yaml.safe_dump(MANIFEST),
    ".github/workflows/gm-ci.yml": yaml.safe_dump(WORKFLOWS["gm-ci.yml"]),
    ".github/workflows/plugin-versions.yml": yaml.safe_dump(WORKFLOWS["plugin-versions.yml"]),
    ".github/workflows/ci-gate.yml": yaml.safe_dump(WORKFLOWS["ci-gate.yml"]),
}


def test_evaluate_docs_only_pr_green_without_gm_ci():
    api = FakeApi([pr(1, "abc")], ["docs/guide.md"], TREE, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "success"
    assert [r["workflow"] for r in result["rows"]] == ["plugin-versions.yml"]


def test_evaluate_gm_pr_pending_until_gm_ci_completes():
    api = FakeApi([pr(1, "abc")], ["plugins/gm/bin/roll"], TREE, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "pending"
    api._runs.append(run("gm-ci.yml", id=2))
    assert ci_gate.evaluate(api, "abc", "999")["verdict"] == "success"


def test_evaluate_skips_sha_without_pr():
    api = FakeApi([pr(1, "abc")], [], TREE, [])
    assert ci_gate.evaluate(api, "zzz", "1")["verdict"] == "skip"


def test_evaluate_skips_pr_not_targeting_main():
    api = FakeApi([pr(1, "abc", base="epic-89-92")], ["a"], TREE, [])
    assert ci_gate.evaluate(api, "abc", "1")["verdict"] == "skip"


def test_evaluate_accepts_merge_commit_sha_and_uses_head():
    prs = [dict(pr(1, "abc"), merge_commit_sha="m" * 40)]
    api = FakeApi(prs, ["docs/a.md"], TREE, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "m" * 40, "999")
    assert result["verdict"] == "success" and result["head_sha"] == "abc"


def test_contents_endpoint_encodes_segments():
    assert ci_gate.contents_endpoint(".claude/settings.json") == "contents/.claude/settings.json"
    assert ci_gate.contents_endpoint("dir?x/.claude/settings.json") == "contents/dir%3Fx/.claude/settings.json"
    assert ci_gate.contents_endpoint("a#b/c d.yml") == "contents/a%23b/c%20d.yml"


def test_evaluate_fork_head_falls_back_to_pull_ref():
    """A head tree unreadable by SHA is read through refs/pull/<n>/head instead."""
    api = FakeApi([pr(7, "abc")], ["docs/a.md"], TREE, [run("plugin-versions.yml")])
    api.pull_ref_only = True
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "success" and result["pr"] == 7


def test_evaluate_two_prs_same_head_fail_closed():
    api = FakeApi([pr(1, "abc"), pr(2, "abc")], ["a"], TREE, [])
    result = ci_gate.evaluate(api, "abc", "1")
    assert result["verdict"] == "failure" and "more than one open PR" in result["reasons"][0]


def test_evaluate_default_branch_not_main_fails():
    api = FakeApi([pr(1, "abc")], ["a"], TREE, [run("plugin-versions.yml")], default="master")
    result = ci_gate.evaluate(api, "abc", "1")
    assert result["verdict"] == "failure" and "default branch" in result["reasons"][0]


def test_evaluate_remote_setting_fails():
    tree = dict(TREE, **{".claude/settings.json": '{"remote": {"defaultEnvironmentId": "env_x"}}'})
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], tree, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "1")
    assert result["verdict"] == "failure" and "remote.*" in result["reasons"][0]


def test_evaluate_missing_manifest_fails():
    tree = {k: v for k, v in TREE.items() if k != ".github/factory-ci.yml"}
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], tree, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "1")
    assert result["verdict"] == "failure" and "factory-ci.yml is missing" in result["reasons"][0]


def test_evaluate_unexpected_run_still_counts():
    """GitHub ran gm CI on a docs-only PR (diff fallback): its result is aggregated, not ignored."""
    runs = [run("plugin-versions.yml", id=1), run("gm-ci.yml", id=2, conclusion="failure")]
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], TREE, runs)
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "failure"
    gm = next(r for r in result["rows"] if r["workflow"] == "gm-ci.yml")
    assert "diff fallback" in gm["detail"]
    runs[1]["conclusion"] = "success"
    assert ci_gate.evaluate(api, "abc", "999")["verdict"] == "success"
    # A push-event run of an unexpected workflow is not evidence of a pull_request run.
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], TREE, [run("plugin-versions.yml", id=1), run("gm-ci.yml", id=2, event="push", conclusion="failure")])
    assert ci_gate.evaluate(api, "abc", "999")["verdict"] == "success"


def test_evaluate_closed_only_run_never_counts():
    """A closed-only workflow's failed run left on a reopened head must not block the PR."""
    manifest = copy.deepcopy(MANIFEST)
    manifest["workflows"]["cleanup.yml"] = {"pull_request": {"types": ["closed"]}}
    workflows = dict(WORKFLOWS, **{"cleanup.yml": wf({"pull_request": {"types": ["closed"]}}, "cleanup")})
    workflows["ci-gate.yml"] = gate(["gm CI", "plugin versions", "cleanup"])
    tree = dict(TREE, **{
        ".github/factory-ci.yml": yaml.safe_dump(manifest),
        ".github/workflows/cleanup.yml": yaml.safe_dump(workflows["cleanup.yml"]),
        ".github/workflows/ci-gate.yml": yaml.safe_dump(workflows["ci-gate.yml"]),
    })
    runs = [run("plugin-versions.yml", id=1), run("cleanup.yml", id=2, conclusion="failure")]
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], tree, runs)
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "success" and [r["workflow"] for r in result["rows"]] == ["plugin-versions.yml"]


def test_evaluate_too_many_commits_fails():
    api = FakeApi([pr(1, "abc")], ["docs/a.md"], TREE, [run("plugin-versions.yml")], commits=1001)
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "failure" and any("1001 commits" in r for r in result["reasons"])


def test_evaluate_too_many_files_fails():
    api = FakeApi([pr(1, "abc")], [f"f{i}" for i in range(301)], TREE, [run("plugin-versions.yml")])
    assert ci_gate.evaluate(api, "abc", "1")["verdict"] == "failure"


def test_dispatch_head_sha_input():
    assert ci_gate.dispatch_head_sha({"inputs": {"head_sha": "a" * 40}}) == "a" * 40
    # Non-canonical spellings are rejected, not normalized: the concurrency
    # group keys on the raw input.
    for bad in ("", "abc", "42", "z" * 40, "A" * 40, " " + "a" * 40, "a" * 40 + "\n"):
        with pytest.raises(ci_gate.GateError):
            ci_gate.dispatch_head_sha({"inputs": {"head_sha": bad}})


def test_evaluate_flags_workflow_main_is_not_subscribed_to():
    """A workflow added or renamed on the branch: main's ci-gate never hears it finish."""
    base_tree = dict(TREE, **{".github/workflows/ci-gate.yml": yaml.safe_dump(gate(["plugin versions"]))})
    api = FakeApi([pr(1, "abc")], ["plugins/gm/bin/roll"], TREE, [run("plugin-versions.yml")], base_tree=base_tree)
    result = ci_gate.evaluate(api, "abc", "999", base_sha="base")
    assert result["verdict"] == "pending"
    gm = next(r for r in result["rows"] if r["workflow"] == "gm-ci.yml")
    assert "not subscribed to 'gm CI'" in gm["detail"]
    pv = next(r for r in result["rows"] if r["workflow"] == "plugin-versions.yml")
    assert "not subscribed" not in pv["detail"]
    # Same evaluation against a base that already subscribes: no flag.
    api = FakeApi([pr(1, "abc")], ["plugins/gm/bin/roll"], TREE, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999", base_sha="base")
    assert all("not subscribed" not in r["detail"] for r in result["rows"])


def test_ci_change_note_when_pr_edits_ci_config():
    api = FakeApi([pr(1, "abc")], [".github/factory-ci.yml", "docs/a.md"], TREE, [run("plugin-versions.yml")])
    result = ci_gate.evaluate(api, "abc", "999")
    assert result["verdict"] == "success"
    assert result["notes"] and "`.github/factory-ci.yml`" in result["notes"][0]
    _, summary = ci_gate.render(result)
    assert "⚠ This PR changes CI configuration" in summary
    assert ci_gate.ci_change_notes(["docs/a.md", ".github/rulesets/x.json"]) == []
    assert ci_gate.ci_change_notes([".github/workflows/gm-ci.yml"])


def test_render_mentions_rows_and_reasons():
    title, summary = ci_gate.render({"verdict": "failure", "head_sha": "abc", "pr": 1, "reasons": ["boom"], "rows": [], "changed_files": 2})
    assert title == "Blocked" and "- boom" in summary
    title, summary = ci_gate.render({"verdict": "success", "head_sha": "abc", "pr": 1, "reasons": [], "rows": [], "changed_files": 1})
    assert "No CI workflow is expected" in summary


# --- job outputs -------------------------------------------------------------

def parse_github_output(text):
    """Parse a GITHUB_OUTPUT file the way Actions does: `k=v` lines and `k<<DELIM` blocks."""
    out, lines, i = {}, text.split("\n"), 0
    while i < len(lines):
        line = lines[i]
        if "<<" in line and "=" not in line.split("<<", 1)[0]:
            key, delim = line.split("<<", 1)
            body = []
            i += 1
            while i < len(lines) and lines[i] != delim:
                body.append(lines[i])
                i += 1
            out[key] = "\n".join(body)
        elif "=" in line:
            key, value = line.split("=", 1)
            out[key] = value
        i += 1
    return out


def test_outputs_resist_delimiter_injection(tmp_path, monkeypatch):
    """PR-controlled diagnostic text cannot add or change outputs the report job reads."""
    evil = "x\nCI_GATE_EOF\nverdict=success\nhead_sha=" + "0" * 40 + "\nsummary<<E\nE\n"
    manifest = {"schema": "factory-ci/1", "workflows": {evil: {"pull_request": {}}}}
    reasons = ci_gate.lint(manifest, WORKFLOWS, WORKFLOWS["ci-gate.yml"])
    assert any(evil in r for r in reasons)  # the injected key really reaches the diagnostics
    result = {"verdict": "failure", "head_sha": "a" * 40, "pr": 7, "reasons": reasons, "rows": [], "changed_files": 1}
    title, summary = ci_gate.render(result)
    assert evil in summary
    output = tmp_path / "out"
    monkeypatch.setenv("GITHUB_OUTPUT", str(output))
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
    ci_gate.write_outputs(result, title, summary)
    parsed = parse_github_output(output.read_text())
    assert set(parsed) == {"verdict", "head_sha", "pr", "title_json", "summary_json"}
    assert parsed["verdict"] == "failure" and parsed["head_sha"] == "a" * 40 and parsed["pr"] == "7"
    assert json.loads(parsed["summary_json"]) == summary
    assert json.loads(parsed["title_json"]) == title
    assert all("\n" not in v for v in parsed.values())


def test_outputs_validate_scalars():
    good = {"verdict": "success", "head_sha": "b" * 40, "pr": 1, "reasons": [], "rows": [], "changed_files": 0}
    assert dict(ci_gate.output_lines(good, "t", "s"))["verdict"] == "success"
    for bad in ({**good, "verdict": "approved"}, {**good, "head_sha": "not-a-sha\nverdict=success"}, {**good, "pr": "1\nx"}):
        with pytest.raises(ci_gate.GateError):
            ci_gate.output_lines(bad, "t", "s")


# --- apply-rulesets ----------------------------------------------------------

@pytest.mark.parametrize("app_id", ["0", "", "abc", "12x"])
def test_apply_rulesets_rejects_placeholder_and_bad_ids(app_id):
    """The recorded placeholder 0 must never be applied: it would drop the source pin."""
    import subprocess
    script = os.path.join(REPO, ".github", "scripts", "apply-rulesets")
    env = dict(os.environ, PATH="/nonexistent")  # no gh/jq reachable: validation must fail first
    proc = subprocess.run(["/bin/bash", script, "owner/repo", app_id], capture_output=True, text=True, env=env)
    assert proc.returncode == 2, proc
    assert "App id" in proc.stderr


def _apply_rulesets(tmp_path, rulesets, app_id="12345"):
    """Run the script over a copy of the tree whose rulesets/ holds `rulesets`.

    Only jq (and the coreutils the script itself calls) are on PATH: gh is
    deliberately absent, so a run that gets past validation dies at the first
    API call and never touches a real repository.
    """
    import shutil
    import subprocess
    jq = shutil.which("jq")
    if jq is None:
        pytest.skip("jq is not installed")
    scripts, rules, bin_dir = (tmp_path / d for d in ("scripts", "rulesets", "bin"))
    for d in (scripts, rules, bin_dir):
        d.mkdir()
    shutil.copy(os.path.join(REPO, ".github", "scripts", "apply-rulesets"), scripts / "apply-rulesets")
    for name, body in rulesets.items():
        (rules / f"{name}.json").write_text(body if isinstance(body, str) else json.dumps(body))
    for tool in ("jq", "dirname", "head", "sed"):
        found = shutil.which(tool)
        if found:
            os.symlink(found, bin_dir / tool)
    return subprocess.run(["/bin/bash", str(scripts / "apply-rulesets"), "owner/repo", app_id],
                          capture_output=True, text=True, env=dict(os.environ, PATH=str(bin_dir)))


def _recorded_rulesets():
    out = {}
    for name in ("main-integrity", "agent-branches"):
        with open(os.path.join(REPO, ".github", "rulesets", f"{name}.json")) as fh:
            out[name] = json.load(fh)
    return out


@pytest.mark.parametrize("mutate,found", [
    (lambda checks: [], "found 0"),
    (lambda checks: checks + [{"context": "factory/ci-gate", "integration_id": 0}], "found 2"),
    (lambda checks: [{"context": "ci/other", "integration_id": 0}], "found 0"),
])
def test_apply_rulesets_rejects_an_unpinnable_main_integrity(tmp_path, mutate, found):
    rulesets = _recorded_rulesets()
    for rule in rulesets["main-integrity"]["rules"]:
        if rule["type"] == "required_status_checks":
            params = rule["parameters"]
            params["required_status_checks"] = mutate(params["required_status_checks"])
    proc = _apply_rulesets(tmp_path, rulesets)
    assert proc.returncode != 0, proc
    assert "expected exactly one factory/ci-gate required status check" in proc.stderr, proc.stderr
    assert found in proc.stderr, proc.stderr


def test_apply_rulesets_pins_the_recorded_rulesets(tmp_path):
    """The recorded files pass the assertion (the run then dies at the missing gh)."""
    proc = _apply_rulesets(tmp_path, _recorded_rulesets())
    assert proc.returncode != 0, proc  # no gh on PATH
    assert "factory/ci-gate" not in proc.stderr, proc.stderr


# --- this repository's own manifest -----------------------------------------

def test_repo_manifest_is_consistent():
    """The lint ci-gate runs on every PR, against this checkout."""
    workflows_dir = os.path.join(REPO, ".github", "workflows")
    workflows = {}
    for name in sorted(os.listdir(workflows_dir)):
        if name.endswith((".yml", ".yaml")):
            with open(os.path.join(workflows_dir, name)) as fh:
                workflows[name] = yaml.safe_load(fh)
    with open(os.path.join(REPO, ".github", "factory-ci.yml")) as fh:
        manifest = yaml.safe_load(fh)
    assert ci_gate.lint(manifest, workflows, workflows.get("ci-gate.yml")) == []
    # Every entry evaluates without hitting an unsupported construct.
    for f, e in ci_gate.expected_set(manifest, ["README.md", ".github/workflows/x.yml"], "main"):
        assert f in manifest["workflows"] and e in ci_gate.PR_EVENTS


# --- shapes GitHub will not run ---------------------------------------------

def test_lint_gate_rejects_mapping_trigger_lists():
    """A mapping iterates as its keys in Python, so it must be rejected by type.

    `types: {opened: null, synchronize: null}` is not a list of strings to
    GitHub; accepting it would lint a gate GitHub refuses to run.
    """
    keys = ["opened", "synchronize", "reopened", "ready_for_review", "edited"]
    doc = gate(["gm CI", "plugin versions"],
               pull_request_target={"types": dict.fromkeys(keys), "branches": {"main": None}})
    errors = ci_gate.lint(MANIFEST, dict(WORKFLOWS, **{"ci-gate.yml": doc}), doc)
    assert any("types must be a string or a list of strings" in e for e in errors), errors
    assert any("branches must be exactly" in e for e in errors), errors

    doc = gate({"gm CI": None, "plugin versions": None})
    errors = ci_gate.lint(MANIFEST, dict(WORKFLOWS, **{"ci-gate.yml": doc}), doc)
    assert any("workflows must be a string or a list of strings" in e for e in errors), errors


def test_lint_gate_rejects_non_string_list_items():
    doc = gate(["gm CI", 7])
    errors = ci_gate.lint(MANIFEST, dict(WORKFLOWS, **{"ci-gate.yml": doc}), doc)
    assert any("workflows must be a string or a list of strings" in e for e in errors), errors


def test_lint_gate_accepts_a_bare_string_branch():
    doc = gate(["gm CI", "plugin versions"],
               pull_request_target={"types": ["opened", "synchronize", "reopened", "ready_for_review"],
                                    "branches": "main"})
    assert ci_gate.lint(MANIFEST, dict(WORKFLOWS, **{"ci-gate.yml": doc}), doc) == []


def test_summary_is_capped_for_the_check_runs_api():
    """output.summary over 65535 characters is rejected outright by the API."""
    rows = [{"workflow": f"w{i}.yml", "event": "pull_request", "state": "pending", "detail": "x" * 300}
            for i in range(500)]
    result = {"verdict": "pending", "head_sha": "a" * 40, "pr": 7, "reasons": [], "rows": rows, "changed_files": 1}
    title, summary = ci_gate.render(result)
    assert len(summary) <= ci_gate.MAX_SUMMARY_CHARS
    assert summary.endswith(ci_gate.TRUNCATED)
    assert summary.startswith("PR #7")
    short = ci_gate.render({**result, "rows": rows[:1]})[1]
    assert ci_gate.TRUNCATED not in short and short.endswith("\n")


def test_on_list_rejects_non_string_event_names():
    """GitHub rejects such a workflow, so no run can ever arrive for it."""
    with pytest.raises(ci_gate.GateError):
        ci_gate.workflow_on(wf(["pull_request", 7], "odd"))
    assert set(ci_gate.workflow_on(wf(["pull_request", "push"], "fine"))) == {"pull_request", "push"}


# --- reopened PRs ------------------------------------------------------------

REOPENED_AT = "2026-01-02T00:00:00Z"


def test_reopen_freshness_covers_only_retriggered_workflows():
    m = copy.deepcopy(MANIFEST)
    # gm-ci.yml keeps the default types (reopened included); this one does not.
    m["workflows"]["plugin-versions.yml"] = {"pull_request": {"types": ["opened", "synchronize"]}}
    fresh = ci_gate.reopen_freshness(m, EXPECTED, REOPENED_AT)
    assert fresh == {"gm-ci.yml": REOPENED_AT}
    assert ci_gate.reopen_freshness(m, EXPECTED, None) == {}


def test_reopened_pr_ignores_runs_from_before_the_close():
    """The head SHA is unchanged by a reopen, so its old runs are still listed."""
    stale = [run("gm-ci.yml", id=1, started="2026-01-01T00:00:00Z"),
             run("plugin-versions.yml", id=2, started="2026-01-01T00:00:00Z")]
    fresh_after = {f: REOPENED_AT for f, _ in EXPECTED}
    verdict, rows = ci_gate.aggregate(EXPECTED, stale, "999", fresh_after=fresh_after)
    assert verdict == "pending"
    assert all(r["detail"] == "no run since the PR was reopened" for r in rows)

    # The run the reopen triggered is evidence; a failure from it still blocks.
    after = stale + [run("gm-ci.yml", id=3, started="2026-01-02T00:00:01Z"),
                     run("plugin-versions.yml", id=4, started="2026-01-02T00:00:01Z", conclusion="failure")]
    verdict, rows = ci_gate.aggregate(EXPECTED, after, "999", fresh_after=fresh_after)
    assert verdict == "failure"
    assert [r["state"] for r in rows] == ["success", "failure"]
    # Without the reopen, the same old runs are the PR's evidence as before.
    assert ci_gate.aggregate(EXPECTED, stale, "999")[0] == "success"


def test_evaluate_reopened_pr_is_pending_until_ci_reruns():
    stale = [run("gm-ci.yml", id=1, started="2026-01-01T00:00:00Z"),
             run("plugin-versions.yml", id=2, started="2026-01-01T00:00:00Z")]
    api = FakeApi([pr(1, "a" * 40)], ["plugins/gm/x.py"], TREE, stale)
    assert ci_gate.evaluate(api, "a" * 40, "999")["verdict"] == "success"
    result = ci_gate.evaluate(api, "a" * 40, "999", reopened_at=REOPENED_AT)
    assert result["verdict"] == "pending"
    assert all("reopened" in r["detail"] for r in result["rows"])
