import json
import os
import subprocess


def run(roll_path, *args):
    return subprocess.run([roll_path, *args], capture_output=True, text=True)


FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "oracle.json")


# --- standard notation (NdX±M) ---

def test_basic_total_in_range(roll_path):
    p = run(roll_path, "2d6", "--json")
    assert p.returncode == 0, p.stderr
    out = json.loads(p.stdout)
    assert len(out["rolls"]) == 2
    assert 2 <= out["total"] <= 12


def test_modifier_applied(roll_path):
    out = json.loads(run(roll_path, "1d1+5", "--json").stdout)  # d1 always 1
    assert out["total"] == 6
    assert out["modifier"] == 5


def test_default_count_is_one(roll_path):
    out = json.loads(run(roll_path, "d20", "--json").stdout)
    assert len(out["rolls"]) == 1


def test_seed_is_deterministic(roll_path):
    a = run(roll_path, "3d20", "--seed", "42").stdout
    b = run(roll_path, "3d20", "--seed", "42").stdout
    assert a == b and a.strip() != ""


def test_human_output_shows_dice(roll_path):
    out = run(roll_path, "2d6", "--seed", "1").stdout
    assert "2d6" in out and "=" in out


def test_bad_expression_errors(roll_path):
    assert run(roll_path, "notdice").returncode != 0


def test_zero_dice_errors(roll_path):
    assert run(roll_path, "0d6").returncode != 0


def test_negative_modifier(roll_path):
    out = json.loads(run(roll_path, "1d1-3", "--json").stdout)  # 1 + (-3)
    assert out["total"] == -2
    assert out["modifier"] == -3


# --- keep/drop, advantage/disadvantage, exploding ---

def test_keep_highest(roll_path):
    out = json.loads(run(roll_path, "4d1kh3", "--json").stdout)  # all 1s
    assert out["kept"] == [1, 1, 1]
    assert out["total"] == 3


def test_keep_lowest_count(roll_path):
    out = json.loads(run(roll_path, "4d1kl2", "--json").stdout)
    assert len(out["kept"]) == 2


def test_advantage_keeps_one_of_two(roll_path):
    out = json.loads(run(roll_path, "1d20", "--adv", "--json").stdout)
    assert len(out["rolls"]) == 2
    assert len(out["kept"]) == 1


def test_disadvantage_keeps_lower(roll_path):
    out = json.loads(run(roll_path, "1d20", "--dis", "--seed", "5", "--json").stdout)
    assert len(out["rolls"]) == 2
    assert out["kept"][0] == min(out["rolls"])


def test_exploding_terminates(roll_path):
    p = run(roll_path, "2d2!", "--seed", "3", "--json")
    assert p.returncode == 0, p.stderr
    assert json.loads(p.stdout)["total"] >= 2


def test_exploding_d1_does_not_hang(roll_path):
    out = json.loads(run(roll_path, "1d1!", "--json").stdout)
    assert out["total"] == 1


# --- ironsworn action roll: 1d6+stat+adds (cap 10) vs two challenge dice ---
# --action-die and --challenge inject dice for deterministic outcome tests (like --seed).

def test_action_strong_hit_beats_both(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--action-die", "3", "--stat", "2",
                         "--challenge", "1", "4", "--json").stdout)
    assert out["score"] == 5  # 3 + 2
    assert out["outcome"] == "strong hit"  # 5 > 1 and 5 > 4
    assert out["match"] is False


def test_action_weak_hit_beats_one(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--action-die", "3", "--stat", "2",
                         "--challenge", "4", "6", "--json").stdout)
    assert out["outcome"] == "weak hit"  # 5 > 4, not > 6


def test_action_miss_beats_neither(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--action-die", "1", "--stat", "0",
                         "--challenge", "5", "8", "--json").stdout)
    assert out["outcome"] == "miss"


def test_action_score_capped_at_10(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--action-die", "6", "--stat", "9",
                         "--adds", "9", "--challenge", "1", "1", "--json").stdout)
    assert out["score"] == 10


def test_action_match_when_challenge_dice_equal(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--action-die", "3", "--stat", "2",
                         "--challenge", "4", "4", "--json").stdout)
    assert out["match"] is True


def test_action_seed_deterministic(roll_path):
    a = run(roll_path, "ironsworn-action", "--stat", "2", "--seed", "9").stdout
    b = run(roll_path, "ironsworn-action", "--stat", "2", "--seed", "9").stdout
    assert a == b and a.strip() != ""


def test_action_default_challenge_is_two_d10(roll_path):
    out = json.loads(run(roll_path, "ironsworn-action", "--stat", "1", "--seed", "4", "--json").stdout)
    assert len(out["challenge"]) == 2
    assert all(1 <= c <= 10 for c in out["challenge"])


# --- oracle table lookup ---

def test_oracle_lookup_in_table(roll_path):
    out = json.loads(run(roll_path, "oracle", "--table", FIXTURE, "--seed", "0", "--json").stdout)
    assert out["result"] in ("No", "Yes")
    assert 1 <= out["roll"] <= 6


def test_oracle_covers_all_faces(roll_path):
    seen = set()
    for s in range(0, 60):
        out = json.loads(run(roll_path, "oracle", "--table", FIXTURE, "--seed", str(s), "--json").stdout)
        seen.add(out["result"])
    assert seen == {"No", "Yes"}
