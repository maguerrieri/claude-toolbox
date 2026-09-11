"""provision-risk-labels: label provisioning + risk:normal backfill (spec 1c)."""
import subprocess
import sys

RISK = ["risk:docs", "risk:low", "risk:normal", "risk:high"]
ALL_LABELS = RISK + ["auto-merge: requested"]
DEFAULT_LABELS = ["bug", "enhancement"]


def run(provision_path, *args):
    return subprocess.run([provision_path, *args], capture_output=True, text=True)


def issue(number, *labels, pr=False):
    doc = {"number": number, "labels": [{"name": l} for l in labels]}
    if pr:
        doc["pull_request"] = {"url": "..."}
    return doc


def labels_of(fake, repo, number):
    issues = fake.state()["repos"][repo]["issues"]
    return sorted(l["name"] for l in next(i for i in issues if i["number"] == number)["labels"])


# --- labels ---


def test_creates_every_missing_label_and_leaves_existing_alone(provision_path, fake_gh):
    fake_gh.seed({"o/r": {"labels": DEFAULT_LABELS + ["risk:low"], "issues": []}})
    p = run(provision_path, "--no-backfill", "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    assert sorted(fake_gh.state()["repos"]["o/r"]["labels"]) == sorted(DEFAULT_LABELS + ALL_LABELS)
    created = [c["body"]["name"] for c in fake_gh.writes()]
    assert sorted(created) == sorted(set(ALL_LABELS) - {"risk:low"})
    assert "label 'risk:low': exists" in p.stdout
    # every created label carries a colour and a description
    for c in fake_gh.writes():
        assert c["body"]["color"] and c["body"]["description"]


def test_second_run_is_a_no_op(provision_path, fake_gh):
    fake_gh.seed({"o/r": {"labels": DEFAULT_LABELS + ALL_LABELS, "issues": []}})
    p = run(provision_path, "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    assert fake_gh.writes() == []


# --- backfill ---


def test_backfill_adds_normal_only_to_unlabelled_open_issues(provision_path, fake_gh):
    fake_gh.seed(
        {
            "o/r": {
                "labels": DEFAULT_LABELS + ALL_LABELS,
                "issues": [
                    issue(1),                       # no risk label -> risk:normal
                    issue(2, "bug"),                # non-risk labels only -> risk:normal
                    issue(3, "risk:low"),           # exactly one known class -> untouched
                    issue(4, "risk:docs", "risk:high"),   # two -> flagged, never edited
                    issue(5, "risk:critical"),      # unknown name -> flagged, never edited
                    issue(6, pr=True),              # a pull request -> skipped entirely
                ],
            }
        }
    )
    p = run(provision_path, "o/r")
    assert p.returncode == 1, p.stdout + p.stderr  # flagged issues remain
    assert labels_of(fake_gh, "o/r", 1) == ["risk:normal"]
    assert labels_of(fake_gh, "o/r", 2) == ["bug", "risk:normal"]
    assert labels_of(fake_gh, "o/r", 3) == ["risk:low"]
    assert labels_of(fake_gh, "o/r", 4) == ["risk:docs", "risk:high"]
    assert labels_of(fake_gh, "o/r", 5) == ["risk:critical"]
    assert labels_of(fake_gh, "o/r", 6) == []
    edited = sorted(c["path"] for c in fake_gh.writes())
    assert edited == ["repos/o/r/issues/1/labels", "repos/o/r/issues/2/labels"]
    assert "#4: MANUAL -- risk:docs, risk:high" in p.stdout
    assert "#5: MANUAL -- risk:critical" in p.stdout
    assert "enumerated 5, remediated 2, untouched 1, flagged 2" in p.stdout
    assert "2 issue(s) need manual remediation" in p.stdout


def test_clean_repo_exits_zero_and_reports_counts(provision_path, fake_gh):
    fake_gh.seed({"o/r": {"labels": ALL_LABELS, "issues": [issue(1, "risk:normal"), issue(2, "risk:docs")]}})
    p = run(provision_path, "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    assert fake_gh.writes() == []
    assert "enumerated 2, remediated 0, untouched 2, flagged 0" in p.stdout


def test_backfill_walks_every_page(provision_path, fake_gh):
    # 250 open issues = two full pages + a short one; the enumerated count must not cap at 30 or 100.
    fake_gh.seed({"o/r": {"labels": ALL_LABELS, "issues": [issue(n) for n in range(1, 251)]}})
    p = run(provision_path, "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    assert "enumerated 250, remediated 250" in p.stdout
    assert len(fake_gh.writes()) == 250
    pages = [c["path"] for c in fake_gh.state()["log"] if "issues?" in c["path"]]
    assert [p.rsplit("page=", 1)[1] for p in pages] == ["1", "2", "3"]


def test_only_open_issues_are_ever_requested(provision_path, fake_gh):
    # the fake asserts state=open on every issue listing; a closed issue is never fetched, so never edited
    fake_gh.seed({"o/r": {"labels": ALL_LABELS, "issues": []}})
    p = run(provision_path, "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    listings = [c["path"] for c in fake_gh.state()["log"] if "/issues?" in c["path"]]
    assert listings and all("state=open" in path for path in listings)


def test_dry_run_writes_nothing(provision_path, fake_gh):
    fake_gh.seed({"o/r": {"labels": DEFAULT_LABELS, "issues": [issue(1), issue(2, "risk:low")]}})
    p = run(provision_path, "--dry-run", "o/r")
    assert p.returncode == 0, p.stdout + p.stderr
    assert fake_gh.writes() == []
    assert fake_gh.state()["repos"]["o/r"]["labels"] == DEFAULT_LABELS
    assert "would create" in p.stdout and "#1: would add risk:normal" in p.stdout
    assert "enumerated 2, remediated 1, untouched 1, flagged 0" in p.stdout


def test_multiple_repos_in_one_invocation(provision_path, fake_gh):
    fake_gh.seed(
        {
            "o/a": {"labels": [], "issues": [issue(1)]},
            "o/b": {"labels": ALL_LABELS, "issues": [issue(7, "risk:high")]},
        }
    )
    p = run(provision_path, "o/a", "o/b")
    assert p.returncode == 0, p.stdout + p.stderr
    assert sorted(fake_gh.state()["repos"]["o/a"]["labels"]) == sorted(ALL_LABELS)
    assert labels_of(fake_gh, "o/a", 1) == ["risk:normal"]
    assert labels_of(fake_gh, "o/b", 7) == ["risk:high"]


# --- errors ---


def test_usage_errors(provision_path, fake_gh):
    fake_gh.seed({})
    assert run(provision_path).returncode == 2
    assert run(provision_path, "not-a-repo").returncode == 2
    assert run(provision_path, "--bogus", "o/r").returncode == 2


def test_api_failure_is_reported_not_swallowed(provision_path, fake_gh):
    fake_gh.seed({"o/r": {"labels": [], "issues": []}})  # a repo the fake knows nothing about -> gh api fails
    p = run(provision_path, "o/missing")
    assert p.returncode == 2
    assert "error:" in p.stderr


def test_no_transport_is_a_hard_error(provision_path, tmp_path, monkeypatch):
    monkeypatch.setenv("PATH", str(tmp_path))  # no gh anywhere
    monkeypatch.delenv("GH_TOKEN", raising=False)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)
    p = subprocess.run([sys.executable, provision_path, "o/r"], capture_output=True, text=True)
    assert p.returncode == 2
    assert "neither `gh` on PATH nor GH_TOKEN/GITHUB_TOKEN" in p.stderr


def test_token_transport_wraps_connection_failures(provision_path, tmp_path, monkeypatch):
    # No gh on PATH + a token selects the HTTPS transport; a URLError (DNS/TLS/refused) must
    # surface as the script's own ApiError, not a traceback (Copilot review on #113).
    import importlib.util
    import urllib.error
    import urllib.request

    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setenv("GH_TOKEN", "dummy")
    spec = importlib.util.spec_from_loader("provision_risk_labels", loader=None, origin=provision_path)
    module = importlib.util.module_from_spec(spec)
    with open(provision_path) as f:
        exec(compile(f.read(), provision_path, "exec"), module.__dict__)

    def refuse(request):
        raise urllib.error.URLError("connection refused")

    monkeypatch.setattr(urllib.request, "urlopen", refuse)
    api = module.Api(dry_run=False)
    assert api.gh is None
    try:
        api.call("GET", "repos/o/r/labels")
    except module.ApiError as exc:
        assert "connection refused" in str(exc)
    else:
        raise AssertionError("URLError was not wrapped in ApiError")
