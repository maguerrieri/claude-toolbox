import os
import subprocess


def run(forge_path, *args):
    return subprocess.run([forge_path, *args], capture_output=True, text=True)


RESERVOIR = """# weather frame
## Axes
| Axis | Values |
|---|---|
| sky | clear, overcast, storm |

## Reservoir
- [insider] Ash falls like grey snow; the lanterns gutter.
- A wind that carries voices from the burned village.
    It worsens after dark.
- Salt rain that stings open wounds.

## Cold storage
- (incoherent) the sun is a clock
"""


def test_harvest_writes_reservoir_entries(forge_path, tmp_path):
    res = tmp_path / "weather.md"; res.write_text(RESERVOIR)
    table = tmp_path / "tables" / "weather.md"
    p = run(forge_path, "harvest", str(res), str(table))
    assert p.returncode == 0, p.stderr
    body = table.read_text()
    assert body.count("\n- ") + body.startswith("- ") >= 1
    assert "Ash falls like grey snow" in body
    assert "It worsens after dark." in body          # block-rule continuation kept
    assert "the sun is a clock" not in body          # cold storage NOT harvested


def test_harvest_result_is_rollable(forge_path, roll_path, tmp_path):
    res = tmp_path / "r.md"; res.write_text(RESERVOIR)
    table = tmp_path / "t.md"
    run(forge_path, "harvest", str(res), str(table))
    r = subprocess.run([roll_path, "table", str(table), "--seed", "1"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and "table" in r.stdout   # foundation roller accepts it


def test_harvest_no_reservoir_errors(forge_path, tmp_path):
    res = tmp_path / "empty.md"; res.write_text("# f\n## Axes\n| a | b |\n")
    p = run(forge_path, "harvest", str(res), str(tmp_path / "t.md"))
    assert p.returncode != 0 and "Reservoir" in p.stderr
