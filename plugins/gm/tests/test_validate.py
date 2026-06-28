import os
import subprocess


def run(validate_path, *args):
    return subprocess.run([validate_path, *args], capture_output=True, text=True)


ADAPTERS = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "adapters"))


def test_real_adapters_all_valid(validate_path):
    # every shipped adapter (generic, ironsworn-core, ironsworn, starforged) must validate
    p = run(validate_path, "--all", ADAPTERS)
    assert p.returncode == 0, p.stdout + p.stderr


def test_missing_extends_parent_fails(validate_path, tmp_path):
    d = os.path.join(str(tmp_path), "child")
    os.makedirs(os.path.join(d, "oracles"), exist_ok=True)
    with open(os.path.join(d, "adapter.md"), "w") as f:
        f.write("---\nname: child\nextends: nonexistent\n---\n\n# child\n")
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


# --- MD table validation ---

def _adapter(root, name, oracle_md=None):
    """Minimal adapter dir builder for table tests."""
    d = os.path.join(str(root), name)
    os.makedirs(os.path.join(d, "oracles"), exist_ok=True)
    body = f"# {name}\nSee `oracles/x.md`.\n" if oracle_md is not None else f"# {name}\n"
    with open(os.path.join(d, "adapter.md"), "w") as f:
        f.write("---\nname: " + name + "\n---\n\n" + body)
    if oracle_md is not None:
        with open(os.path.join(d, "oracles", "x.md"), "w") as f:
            f.write(oracle_md)
    return d


def test_table_valid(validate_path, tmp_path):
    d = _adapter(tmp_path, "good", oracle_md="- [50] No\n- [50] Yes\n")
    assert run(validate_path, d).returncode == 0


def test_table_zero_weight_fails(validate_path, tmp_path):
    d = _adapter(tmp_path, "bad", oracle_md="- [0] nope\n- ok\n")
    p = run(validate_path, d)
    assert p.returncode == 1 and "weight" in p.stdout


def test_table_empty_fails(validate_path, tmp_path):
    d = _adapter(tmp_path, "bad2", oracle_md="# header only\n")
    p = run(validate_path, d)
    assert p.returncode == 1 and "no entries" in p.stdout
