import json
import os
import stat
import textwrap

import pytest

HERE = os.path.dirname(__file__)


@pytest.fixture
def provision_path():
    """Absolute path to scripts/provision-risk-labels."""
    return os.path.abspath(os.path.join(HERE, "..", "scripts", "provision-risk-labels"))


# A stand-in for the gh CLI that serves `gh api` from a JSON state file and
# records every mutating call. Only the surface provision-risk-labels uses:
#   gh api -X GET  repos/O/R/labels?per_page=N&page=M
#   gh api -X POST repos/O/R/labels --input -
#   gh api -X GET  repos/O/R/issues?state=open&per_page=N&page=M
#   gh api -X POST repos/O/R/issues/<n>/labels --input -
FAKE_GH = textwrap.dedent(
    '''\
    #!/usr/bin/env python3
    import json, os, re, sys
    from urllib.parse import urlparse, parse_qs

    state_file = os.environ["FAKE_GH_STATE"]
    with open(state_file) as f:
        state = json.load(f)
    args = sys.argv[1:]
    assert args[0] == "api", args
    method = "GET"
    body = None
    rest = []
    i = 1
    while i < len(args):
        if args[i] == "-X":
            method = args[i + 1]; i += 2
        elif args[i] == "--input":
            assert args[i + 1] == "-"; body = json.load(sys.stdin); i += 2
        else:
            rest.append(args[i]); i += 1
    (path,) = rest
    url = urlparse(path)
    query = {k: v[0] for k, v in parse_qs(url.query).items()}
    m = re.match(r"repos/([^/]+/[^/]+)/(labels|issues)(?:/(\\d+)/labels)?$", url.path)
    repo, kind, issue_no = m.group(1), m.group(2), m.group(3)
    repo_state = state["repos"][repo]
    state.setdefault("log", []).append({"method": method, "path": path, "body": body})

    def page(items):
        per_page = int(query["per_page"]); n = int(query["page"])
        return items[(n - 1) * per_page : n * per_page]

    if method == "GET" and kind == "labels":
        print(json.dumps(page([{"name": n} for n in repo_state["labels"]])))
    elif method == "POST" and kind == "labels":
        if body["name"] in repo_state["labels"]:
            sys.stderr.write("HTTP 422: Validation Failed (already_exists)\\n"); sys.exit(1)
        repo_state["labels"].append(body["name"])
        print(json.dumps(body))
    elif method == "GET" and kind == "issues" and issue_no is None:
        assert query.get("state") == "open", "must only ever list open issues"
        print(json.dumps(page(repo_state["issues"])))
    elif method == "POST" and kind == "issues" and issue_no is not None:
        for label in body["labels"]:
            if label not in repo_state["labels"]:
                sys.stderr.write("HTTP 422: label not found\\n"); sys.exit(1)
        issue = next(i for i in repo_state["issues"] if i["number"] == int(issue_no))
        issue.setdefault("labels", []).extend({"name": l} for l in body["labels"])
        print(json.dumps(issue["labels"]))
    else:
        sys.stderr.write(f"fake gh: unsupported {method} {path}\\n"); sys.exit(1)
    with open(state_file, "w") as f:
        json.dump(state, f)
    '''
)


@pytest.fixture
def fake_gh(tmp_path, monkeypatch):
    """Put a fake `gh` first on PATH; return a helper that seeds/reads its state."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    state_file = tmp_path / "state.json"
    monkeypatch.setenv("PATH", f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_GH_STATE", str(state_file))
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)

    class Fake:
        def seed(self, repos):
            state_file.write_text(json.dumps({"repos": repos, "log": []}))

        def state(self):
            return json.loads(state_file.read_text())

        def writes(self):
            return [c for c in self.state()["log"] if c["method"] != "GET"]

    return Fake()
