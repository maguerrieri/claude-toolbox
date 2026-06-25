import json
import os
import subprocess


def run(validate_path, *args):
    return subprocess.run([validate_path, *args], capture_output=True, text=True)


ADAPTERS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "adapters"))


def _write_adapter(root, name, frontmatter, oracle=None):
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "oracles"), exist_ok=True)
    with open(os.path.join(d, "adapter.md"), "w") as f:
        f.write("---\n" + frontmatter + "\n---\n\n# " + name + "\n")
    if oracle is not None:
        with open(os.path.join(d, "oracles", "t.json"), "w") as f:
            json.dump(oracle, f)
    return d


def test_real_adapters_all_valid(validate_path):
    # every shipped adapter (generic, ironsworn-core, ironsworn, starforged) must validate
    p = run(validate_path, "--all", ADAPTERS)
    assert p.returncode == 0, p.stdout + p.stderr


def test_valid_minimal_adapter_passes(validate_path, tmp_path):
    d = _write_adapter(str(tmp_path), "ok", 'name: ok\ndice: ["1d6"]',
                       {"die": "1d6", "rows": [{"max": 3, "result": "lo"}, {"max": 6, "result": "hi"}]})
    assert run(validate_path, d).returncode == 0


def test_nonascending_oracle_fails(validate_path, tmp_path):
    d = _write_adapter(str(tmp_path), "bad", "name: bad",
                       {"die": "1d6", "rows": [{"max": 6, "result": "a"}, {"max": 3, "result": "b"}]})
    p = run(validate_path, d)
    assert p.returncode == 1
    assert "ascending" in p.stdout


def test_incomplete_coverage_fails(validate_path, tmp_path):
    d = _write_adapter(str(tmp_path), "bad2", "name: bad2",
                       {"die": "1d100", "rows": [{"max": 50, "result": "a"}]})
    p = run(validate_path, d)
    assert p.returncode == 1
    assert "coverage" in p.stdout


def test_duplicate_max_fails(validate_path, tmp_path):
    d = _write_adapter(str(tmp_path), "bad3", "name: bad3",
                       {"die": "1d6", "rows": [{"max": 6, "result": "a"}, {"max": 6, "result": "b"}]})
    p = run(validate_path, d)
    assert p.returncode == 1
    assert "duplicate" in p.stdout


def test_missing_extends_parent_fails(validate_path, tmp_path):
    d = _write_adapter(str(tmp_path), "child", "name: child\nextends: nonexistent")
    p = run(validate_path, d)
    assert p.returncode == 1
    assert "extends" in p.stdout


# --- personas ---

PERSONAS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "personas"))


def test_real_personas_all_valid(validate_path):
    p = run(validate_path, "--personas", "--all", PERSONAS)
    assert p.returncode == 0, p.stdout + p.stderr


def test_persona_missing_chronicle_identity_fails(validate_path, tmp_path):
    d = os.path.join(str(tmp_path), "p")
    os.makedirs(d)
    with open(os.path.join(d, "persona.md"), "w") as f:
        f.write("---\nname: p\n---\n\n# P\n")
    p = run(validate_path, "--personas", d)
    assert p.returncode == 1
    assert "chronicle_identity" in p.stdout


def test_persona_naming_mechanic_fails(validate_path, tmp_path):
    d = os.path.join(str(tmp_path), "p")
    os.makedirs(d)
    with open(os.path.join(d, "persona.md"), "w") as f:
        f.write("---\nname: p\nchronicle_identity:\n  author: P\n---\n\n# P\nNarrate every strong hit with relish.\n")
    p = run(validate_path, "--personas", d)
    assert p.returncode == 1
    assert "mechanic" in p.stdout
