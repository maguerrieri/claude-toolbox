"""Autosave: session binding, the Stop hook's raw play log, and per-turn checkpoints."""
import glob
import json
import os
import shutil
import subprocess
import time

HERE = os.path.dirname(__file__)
FIXTURE = os.path.join(HERE, "fixtures", "transcripts", "play-session.jsonl")
HOOKS_JSON = os.path.join(HERE, "..", "hooks", "hooks.json")
SID = "f1x7ure0-0000-4000-8000-000000000001"


def gm_env(tmp_path, **extra):
    e = dict(os.environ)
    for k in ("GM_SESSION_ID", "CLAUDE_SESSION_ID", "CLAUDE_PLUGIN_DATA", "CLAUDE_ENV_FILE"):
        e.pop(k, None)
    e["GM_DATA_DIR"] = str(tmp_path / "data")
    e.update(extra)
    return e


def run(campaign_path, *args, env, stdin=""):
    return subprocess.run([campaign_path, *args], input=stdin, capture_output=True, text=True, env=env)


def git(d, *args):
    return subprocess.run(["git", "-C", d, *args], capture_output=True, text=True).stdout


def new_campaign(campaign_path, parent, env, name="camp"):
    d = os.path.join(str(parent), name)
    os.makedirs(d)
    with open(os.path.join(d, "campaign.md"), "w") as f:
        f.write("---\nadapter: generic\n---\n")
    run(campaign_path, "init", d, env=env)
    return d


def copy_fixture(tmp_path):
    t = str(tmp_path / "transcript.jsonl")
    shutil.copy(FIXTURE, t)
    return t


def play_fixture(campaign_path, env, tmp_path):
    """Feed the fixture transcript turn by turn, running the Stop hook after each
    turn as Claude Code would (turns start at prompts u5 and u13)."""
    t = str(tmp_path / "transcript.jsonl")
    open(t, "w").close()
    turn = []
    for line in open(FIXTURE):
        if json.loads(line).get("uuid") in ("u5", "u13"):
            with open(t, "a") as f:
                f.writelines(turn)
            hook(campaign_path, env, t)
            turn = []
        turn.append(line)
    with open(t, "a") as f:
        f.writelines(turn)
    hook(campaign_path, env, t)
    return t


def hook(campaign_path, env, transcript, sid=SID, event="Stop"):
    payload = {"session_id": sid, "transcript_path": transcript, "cwd": "/",
               "hook_event_name": event, "stop_hook_active": False}
    return run(campaign_path, "hook-autosave", env=env, stdin=json.dumps(payload))


def raw_files(d):
    return sorted(glob.glob(os.path.join(d, "log", "raw", "*.md")))


def raw_text(d):
    return "".join(open(p).read() for p in raw_files(d))


def append_lines(transcript, *entries):
    with open(transcript, "a") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


def user(text):
    return {"type": "user", "isSidechain": False, "message": {"role": "user", "content": text}}


def gm(text):
    return {"type": "assistant", "isSidechain": False,
            "message": {"model": "claude-opus-5-5", "role": "assistant",
                        "content": [{"type": "text", "text": text}]}}


# ---- binding --------------------------------------------------------------

def test_bind_without_session_id_is_a_clean_notice(campaign_path, tmp_path):
    e = gm_env(tmp_path)
    d = new_campaign(campaign_path, tmp_path, e)
    p = run(campaign_path, "bind", d, env=e)
    assert p.returncode == 0
    assert "autosave unavailable" in p.stdout
    assert not os.path.exists(tmp_path / "data" / "sessions")


def test_bind_ignores_another_plugins_session_id(campaign_path, tmp_path):
    """CLAUDE_SESSION_ID (ticket-workflow's export) comes without GM_DATA_DIR, so a
    binding keyed by it could land where the Stop hook never looks."""
    e = gm_env(tmp_path, CLAUDE_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    p = run(campaign_path, "bind", d, env=e)
    assert "autosave unavailable" in p.stdout
    assert not os.path.exists(tmp_path / "data" / "sessions")


def test_bind_reads_session_id_from_env(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    p = run(campaign_path, "bind", d, env=e)
    assert p.returncode == 0, p.stderr
    assert "autosave on" in p.stdout
    binding = json.load(open(tmp_path / "data" / "sessions" / f"{SID}.json"))
    assert binding["campaign"] == os.path.realpath(d)


def test_bind_refuses_a_non_campaign_dir(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    empty = tmp_path / "not-a-campaign"
    empty.mkdir()
    p = run(campaign_path, "bind", str(empty), env=e)
    assert p.returncode != 0
    assert "campaign.md" in (p.stdout + p.stderr)
    assert not os.path.exists(tmp_path / "data" / "sessions" / f"{SID}.json")


def test_bind_rejects_a_path_like_session_id(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID="../../escape")
    d = new_campaign(campaign_path, tmp_path, e)
    p = run(campaign_path, "bind", d, env=e)
    assert "autosave unavailable" in p.stdout
    assert not os.path.exists(tmp_path / "escape.json")


def test_unbind_stops_autosave(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    assert "autosave off" in run(campaign_path, "unbind", env=e).stdout
    hook(campaign_path, e, copy_fixture(tmp_path))
    assert raw_files(d) == []


# ---- the Stop hook --------------------------------------------------------

def test_unbound_session_is_a_strict_noop(campaign_path, tmp_path):
    e = gm_env(tmp_path)
    d = new_campaign(campaign_path, tmp_path, e)
    before = git(d, "rev-parse", "HEAD")
    p = hook(campaign_path, e, copy_fixture(tmp_path))
    assert p.returncode == 0
    assert p.stdout == "" and p.stderr == ""
    assert raw_files(d) == []
    assert git(d, "rev-parse", "HEAD") == before
    assert not os.path.exists(tmp_path / "data" / "sessions")


def test_bound_turn_is_logged_with_no_model_action(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = str(tmp_path / "transcript.jsonl")
    shutil.copy(FIXTURE, t)
    p = hook(campaign_path, e, t)
    assert p.returncode == 0
    assert p.stdout == ""  # Stop-hook stdout could be read as a decision; stay silent
    shutil.rmtree(os.path.join(d, "log"))
    os.remove(tmp_path / "data" / "sessions" / f"{SID}.json")
    run(campaign_path, "bind", d, env=e)
    play_fixture(campaign_path, e, tmp_path)
    [f] = raw_files(d)
    assert os.path.basename(f).endswith(f"-{SID[:8]}.md")
    text = open(f).read()
    assert "### Player\n\n/gm:play ~/rpg/embervale\n" in text
    assert "Rain hammers the shutters" in text
    assert "What do you do?" in text
    # array-form user content: the text block is the prompt; images leave a placeholder
    assert "I search the cellar for the missing ledger.\n\n[image]" in text
    # a prompt queued mid-turn lives only in a queued_command attachment
    assert "and I light a torch first" in text
    assert "The names in it are all of the dead." in text
    # blocks appear in transcript order
    order = ["/gm:play", "Rain hammers", "I search the cellar", "and I light a torch",
             "You rolled a 17", "I read the ledger aloud", "The names in it"]
    idx = [text.index(s) for s in order]
    assert idx == sorted(idx)


def test_raw_log_never_contains_tool_calls_results_or_harness_noise(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    play_fixture(campaign_path, e, tmp_path)
    text = raw_text(d)
    for leak in ("TOOL-INPUT-SECRET", "TOOL-RESULT-SECRET", "ROLL-TOOL-OUTPUT", "gm-seal",
                 "campaign bind", "THINKING-SECRET", "EXPANDED-COMMAND-PROMPT",
                 "SKILL-LISTING-NOISE", "SYSTEM-NOISE", "REMINDER-NOISE", "PEER-NOISE",
                 "TASK-NOISE", "SIDECHAIN-NOISE", "API-ERROR-NOISE", "Request interrupted",
                 "CAVEAT-NOISE", "bash-input", "STDOUT-NOISE", "COMPACT-NOISE"):
        assert leak not in text, leak


def test_each_turn_is_checkpointed_and_rewindable(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    with open(os.path.join(d, "threads.md"), "w") as f:
        f.write("- The missing ledger (hot)\n")
    t = play_fixture(campaign_path, e, tmp_path)
    first = git(d, "rev-parse", "HEAD").strip()
    assert git(d, "log", "-1", "--format=%s").strip() == "autosave: I read the ledger aloud."
    assert git(d, "status", "--porcelain") == ""  # log + state both committed

    with open(os.path.join(d, "threads.md"), "w") as f:
        f.write("- The missing ledger (resolved)\n")
    append_lines(t, user("I burn the ledger."), gm("It curls into ash."))
    hook(campaign_path, e, t)
    assert git(d, "log", "-1", "--format=%s").strip() == "autosave: I burn the ledger."

    p = run(campaign_path, "rewind", d, "--to", first, env=e)
    assert "rewound to" in p.stdout
    assert open(os.path.join(d, "threads.md")).read() == "- The missing ledger (hot)\n"


def test_later_turns_append_only_new_dialogue(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = play_fixture(campaign_path, e, tmp_path)
    hook(campaign_path, e, t)  # another Stop with nothing new
    assert raw_text(d).count("Rain hammers the shutters") == 1
    commits = git(d, "rev-list", "--count", "HEAD")
    hook(campaign_path, e, t)
    assert git(d, "rev-list", "--count", "HEAD") == commits  # no empty autosave commits

    append_lines(t, user("I pocket the ledger."), gm("Footsteps on the stair."))
    hook(campaign_path, e, t)
    text = raw_text(d)
    assert text.count("Rain hammers the shutters") == 1
    assert text.rstrip().endswith("### Player\n\nI pocket the ledger.\n\n### GM\n\nFootsteps on the stair.")


def test_a_half_written_last_line_waits_for_the_next_turn(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = copy_fixture(tmp_path)
    hook(campaign_path, e, t)
    line = json.dumps(gm("The door creaks open."))
    with open(t, "a") as f:
        f.write(line[:20])  # mid-write: no newline yet
    hook(campaign_path, e, t)
    assert "The door creaks open." not in raw_text(d)
    with open(t, "a") as f:
        f.write(line[20:] + "\n")
    hook(campaign_path, e, t)
    assert raw_text(d).count("The door creaks open.") == 1


def test_first_autosave_starts_at_the_binding_turn(campaign_path, tmp_path):
    """Turns after the bind are logged even if their Stop hooks never ran; turns
    before it (non-gm chatter earlier in the session) are not."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    t = str(tmp_path / "transcript.jsonl")
    append_lines(t, dict(user("unrelated coding question"), timestamp="2000-01-01T00:00:00.000Z"),
                 gm("unrelated answer"),
                 dict(user("<command-name>/gm:play</command-name>"), timestamp="2000-01-02T00:00:00.000Z"),
                 gm("The fog lifts."))
    run(campaign_path, "bind", d, env=e)  # bound "now", during the /gm:play turn
    append_lines(t, dict(user("I walk on."), timestamp="2999-01-01T00:00:00.000Z"), gm("The road."))
    hook(campaign_path, e, t)
    text = raw_text(d)
    assert "unrelated" not in text
    assert "### Player\n\n/gm:play\n\n### GM\n\nThe fog lifts.\n\n### Player\n\nI walk on." in text


def test_first_autosave_without_timestamps_starts_at_the_latest_prompt(campaign_path, tmp_path):
    """Turns before the bind (non-gm chatter earlier in the session) are not logged."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    t = str(tmp_path / "transcript.jsonl")
    append_lines(t, user("unrelated coding question"), gm("unrelated answer"),
                 user("<command-name>/gm:play</command-name>\n<command-args></command-args>"),
                 gm("The fog lifts."))
    run(campaign_path, "bind", d, env=e)
    hook(campaign_path, e, t)
    text = raw_text(d)
    assert "unrelated" not in text
    assert "### Player\n\n/gm:play\n\n### GM\n\nThe fog lifts." in text


def test_deferred_campaign_gets_the_log_but_no_commits(campaign_path, tmp_path):
    vault = tmp_path / "vault"
    vault.mkdir()
    subprocess.run(["git", "-C", str(vault), "init", "-q"])
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, vault, e)  # init defers inside the vault's repo
    assert not os.path.isfile(os.path.join(d, ".gm-campaign"))
    run(campaign_path, "bind", d, env=e)
    play_fixture(campaign_path, e, tmp_path)
    assert "Rain hammers the shutters" in raw_text(d)
    assert git(str(vault), "rev-list", "--all", "--count").strip() == "0"


def test_session_end_flushes_like_stop(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    p = hook(campaign_path, e, copy_fixture(tmp_path), event="SessionEnd")
    assert p.returncode == 0
    assert "The names in it are all of the dead." in raw_text(d)


def test_hook_never_fails_the_turn(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    cases = [
        "",  # empty stdin
        "not json",
        json.dumps(["a", "list"]),
        json.dumps({"session_id": SID}),  # no transcript_path
        json.dumps({"session_id": SID, "transcript_path": str(tmp_path / "missing.jsonl")}),
        json.dumps({"session_id": "../../x", "transcript_path": FIXTURE}),
    ]
    for stdin in cases:
        p = run(campaign_path, "hook-autosave", env=e, stdin=stdin)
        assert p.returncode == 0, (stdin, p.stderr)
        assert p.stdout == ""
    # bound to a campaign that has since been deleted
    shutil.rmtree(d)
    p = hook(campaign_path, e, copy_fixture(tmp_path))
    assert p.returncode == 0 and p.stdout == ""
    # errors land somewhere harmless, not on the turn
    assert os.path.isfile(tmp_path / "data" / "autosave.log")


def test_hook_survives_a_corrupt_transcript_line(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = copy_fixture(tmp_path)
    with open(t, "a") as f:
        f.write("{not json}\n")
    append_lines(t, user("I keep going."), gm("The road bends."))
    assert hook(campaign_path, e, t).returncode == 0
    assert "The road bends." in raw_text(d)


def test_player_markup_is_a_prompt_not_harness_traffic(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = str(tmp_path / "transcript.jsonl")
    append_lines(t, user("<ooc>can we pause the chase?</ooc>"), gm("Of course."))
    hook(campaign_path, e, t)
    assert "### Player\n\n<ooc>can we pause the chase?</ooc>" in raw_text(d)


def test_only_gm_slash_commands_are_play(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = str(tmp_path / "transcript.jsonl")
    append_lines(t, user("<command-name>/gm:oracle</command-name>\n<command-args>is the bridge out?</command-args>"),
                 gm("Yes, but…"))
    hook(campaign_path, e, t)
    append_lines(t, user("<command-name>/model</command-name>\n<command-args>opus</command-args>"),
                 user("<local-command-stdout>Set model to opus</local-command-stdout>"),
                 user("<command-name>/compact</command-name>"),
                 user("I cross anyway."), gm("The planks groan."))
    hook(campaign_path, e, t)
    text = raw_text(d)
    assert "/gm:oracle is the bridge out?" in text and "I cross anyway." in text
    assert "/model" not in text and "/compact" not in text


def test_overlapping_runs_log_a_turn_once(campaign_path, tmp_path):
    """Stop and SessionEnd can overlap (e.g. exiting while Stop still runs)."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = copy_fixture(tmp_path)
    payload = json.dumps({"session_id": SID, "transcript_path": t, "hook_event_name": "SessionEnd"})
    procs = [subprocess.Popen([campaign_path, "hook-autosave"], stdin=subprocess.PIPE, text=True, env=e)
             for _ in range(4)]
    for proc in procs:
        proc.stdin.write(payload)
        proc.stdin.close()
    assert [proc.wait(timeout=20) for proc in procs] == [0, 0, 0, 0]
    assert raw_text(d).count("The names in it are all of the dead.") == 1
    assert git(d, "status", "--porcelain") == ""


def stamped(entry, when):
    return dict(entry, timestamp=when)


def test_a_moved_transcript_resumes_after_the_last_logged_entry(campaign_path, tmp_path):
    """Claude Code can move a session's transcript (e.g. into a worktree's project dir):
    the new file repeats the history, which must not be logged twice."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    old = str(tmp_path / "old.jsonl")
    append_lines(old, stamped(user("<command-name>/gm:play</command-name>"), "2000-01-01T00:00:00.000Z"),
                 stamped(gm("The fog lifts."), "2000-01-01T00:00:01.000Z"))
    run(campaign_path, "bind", d, env=e)
    hook(campaign_path, e, old)
    new = str(tmp_path / "new.jsonl")
    shutil.copy(old, new)
    append_lines(new, stamped(user("I walk on."), "2999-01-01T00:00:00.000Z"),
                 stamped(gm("The road."), "2999-01-01T00:00:01.000Z"))
    hook(campaign_path, e, new)
    text = raw_text(d)
    assert text.count("The fog lifts.") == 1
    assert text.rstrip().endswith("### Player\n\nI walk on.\n\n### GM\n\nThe road.")


def test_a_fresh_transcript_file_is_logged_from_its_start(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    old = str(tmp_path / "old.jsonl")
    append_lines(old, stamped(user("<command-name>/gm:play</command-name>"), "2000-01-01T00:00:00.000Z"),
                 stamped(gm("The fog lifts."), "2000-01-01T00:00:01.000Z"))
    run(campaign_path, "bind", d, env=e)
    hook(campaign_path, e, old)
    new = str(tmp_path / "new.jsonl")  # only the entries written since
    append_lines(new, stamped(user("I walk on."), "2999-01-01T00:00:00.000Z"),
                 stamped(gm("The road."), "2999-01-01T00:00:01.000Z"),
                 stamped(user("I rest."), "2999-01-01T00:01:00.000Z"),
                 stamped(gm("Night falls."), "2999-01-01T00:01:01.000Z"))
    hook(campaign_path, e, new)
    text = raw_text(d)
    assert text.count("The fog lifts.") == 1
    assert "I walk on." in text and "Night falls." in text


def test_stop_waits_for_the_closing_narration_to_land(campaign_path, tmp_path):
    """Claude Code can fire Stop before it writes the turn's last message."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = str(tmp_path / "transcript.jsonl")
    append_lines(t, user("I pick the lock."),
                 {"type": "assistant", "message": {"model": "m", "content": [
                     {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "roll 1d20"}}]}},
                 {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1",
                                                           "content": "14"}]}})
    payload = json.dumps({"session_id": SID, "transcript_path": t, "hook_event_name": "Stop"})
    proc = subprocess.Popen([campaign_path, "hook-autosave"], stdin=subprocess.PIPE, text=True, env=e)
    proc.stdin.write(payload)
    proc.stdin.close()
    time.sleep(0.5)
    append_lines(t, gm("The lock clicks open."))
    assert proc.wait(timeout=10) == 0
    assert "The lock clicks open." in raw_text(d)


def test_bind_needs_the_exported_data_dir(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    del e["GM_DATA_DIR"]
    e["HOME"] = str(tmp_path / "home")
    d = new_campaign(campaign_path, tmp_path, e)
    assert "autosave unavailable" in run(campaign_path, "bind", d, env=e).stdout
    assert "autosave unavailable" in run(campaign_path, "unbind", env=e).stdout
    assert not os.path.exists(tmp_path / "home" / ".claude")


def test_unbind_says_when_nothing_was_bound(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    assert "was not on" in run(campaign_path, "unbind", env=e).stdout


# ---- SessionStart ---------------------------------------------------------

def test_session_start_exports_the_session_id_and_data_dir(campaign_path, tmp_path):
    env_file = tmp_path / "env.sh"
    e = gm_env(tmp_path, CLAUDE_ENV_FILE=str(env_file))
    p = run(campaign_path, "hook-session-start", env=e,
            stdin=json.dumps({"session_id": SID, "source": "startup"}))
    assert p.returncode == 0
    assert p.stdout == ""  # unbound: no context injected
    exported = subprocess.run(["sh", "-c", f". '{env_file}'; echo \"$GM_SESSION_ID|$GM_DATA_DIR\""],
                              capture_output=True, text=True).stdout.strip()
    assert exported == f"{SID}|{tmp_path / 'data'}"


def test_session_start_ignores_a_path_like_session_id(campaign_path, tmp_path):
    env_file = tmp_path / "env.sh"
    e = gm_env(tmp_path, CLAUDE_ENV_FILE=str(env_file))
    p = run(campaign_path, "hook-session-start", env=e,
            stdin=json.dumps({"session_id": "../x", "source": "startup"}))
    assert p.returncode == 0
    assert not env_file.exists() or "GM_SESSION_ID" not in env_file.read_text()


def test_session_start_reminds_a_bound_session_after_compaction(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    p = run(campaign_path, "hook-session-start", env=e,
            stdin=json.dumps({"session_id": SID, "source": "compact"}))
    assert p.returncode == 0
    assert os.path.realpath(d) in p.stdout


def test_session_start_never_fails(campaign_path, tmp_path):
    e = gm_env(tmp_path, CLAUDE_ENV_FILE=str(tmp_path / "no-such-dir" / "env.sh"))
    for stdin in ("", "garbage", json.dumps({"session_id": SID})):
        assert run(campaign_path, "hook-session-start", env=e, stdin=stdin).returncode == 0


# ---- sealing the GM screen from the hooks (#171) --------------------------

def plaintext_screen(d):
    """A legacy plaintext state file, and a crashed subagent's draft from two hours ago."""
    os.makedirs(os.path.join(d, ".gm", "forge"), exist_ok=True)
    with open(os.path.join(d, ".gm", "state.json"), "w") as f:
        json.dump({"clocks": {}, "secrets": {"twist": "Legacy plaintext twist"}}, f)
    orphan = os.path.join(d, ".gm", "forge", "orphan.md")
    with open(orphan, "w") as f:
        f.write("## Reservoir\n- An orphaned draft entry\n")
    old = time.time() - 7200
    os.utime(orphan, (old, old))


def screen_text(d):
    return "".join(open(p).read() for p in glob.glob(os.path.join(d, ".gm", "**", "*"), recursive=True)
                   if os.path.isfile(p))


def test_stop_hook_seals_plaintext_left_behind_the_screen(campaign_path, tmp_path):
    """Legacy plaintext and a crashed subagent's draft get sealed by the hook, outside
    any tool call, so no Bash edit-diff ever shows them going away."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    plaintext_screen(d)
    play_fixture(campaign_path, e, tmp_path)
    text = screen_text(d)
    assert "Legacy plaintext" not in text and "orphaned draft" not in text
    assert not os.path.exists(os.path.join(d, ".gm", "forge", "orphan.md"))  # dropped
    assert "Legacy plaintext twist" in run(campaign_path, "gm-reveal", d, "twist", env=e).stdout
    assert git(d, "status", "--porcelain") == ""  # the sealed files were checkpointed


def test_stop_hook_commits_a_seal_even_with_no_new_dialogue(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    t = play_fixture(campaign_path, e, tmp_path)
    plaintext_screen(d)
    assert hook(campaign_path, e, t).returncode == 0  # nothing new in the transcript
    assert "Legacy plaintext" not in screen_text(d)
    assert git(d, "log", "-1", "--format=%s").strip() == "gm: seal the screen"


def test_session_start_seals_a_bound_campaigns_screen(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    plaintext_screen(d)
    p = run(campaign_path, "hook-session-start", env=e,
            stdin=json.dumps({"session_id": SID, "source": "resume"}))
    assert p.returncode == 0 and os.path.realpath(d) in p.stdout
    assert "Legacy plaintext" not in screen_text(d)
    assert "Legacy plaintext" not in p.stdout


def post_bash(env, command, sid=SID):
    """The PostToolUse hook exactly as hooks.json runs it (through sh, with its filter)."""
    cmd = json.load(open(HOOKS_JSON))["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
    payload = {"session_id": sid, "hook_event_name": "PostToolUse", "tool_name": "Bash",
               "tool_input": {"command": command}, "tool_response": {"stdout": ""}}
    e = dict(env, CLAUDE_PLUGIN_ROOT=os.path.abspath(os.path.join(HERE, "..")))
    return subprocess.run(["sh", "-c", cmd], input=json.dumps(payload),
                          capture_output=True, text=True, env=e)


def test_binding_seals_legacy_plaintext_before_the_first_gameplay_write(campaign_path, tmp_path):
    """The first gm-clock on an older campaign would rewrite its plaintext state in view
    of the diff; the hook right after `campaign bind` seals it first, out of view."""
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    plaintext_screen(d)
    run(campaign_path, "bind", d, env=e)
    p = post_bash(e, f'campaign bind "{d}"')
    assert p.returncode == 0 and p.stdout == ""
    assert "Legacy plaintext" not in screen_text(d)
    assert "Legacy plaintext twist" in run(campaign_path, "gm-reveal", d, "twist", env=e).stdout


def test_post_bash_ignores_everything_but_a_bind(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    plaintext_screen(d)
    for command in ("ls -la", "roll 1d20", f"campaign gm-list {d}", "echo rebind"):
        assert post_bash(e, command).returncode == 0
    assert "Legacy plaintext" in screen_text(d)  # untouched: not a bind
    other = gm_env(tmp_path)
    assert post_bash(other, f"campaign bind {d}", sid="another-session").returncode == 0
    assert "Legacy plaintext" in screen_text(d)  # unbound session: strict no-op


def test_a_failing_seal_never_costs_the_turn(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    os.makedirs(os.path.join(d, ".gm"))
    with open(os.path.join(d, ".gm", "state.json"), "w") as f:
        f.write('{"secrets": {}}')
    os.chmod(os.path.join(d, ".gm"), 0o500)  # can't write the sealed copy
    try:
        play_fixture(campaign_path, e, tmp_path)
    finally:
        os.chmod(os.path.join(d, ".gm"), 0o700)
    assert "Rain hammers the shutters" in raw_text(d)  # the turn still got logged
    assert "sealing .gm/" in open(tmp_path / "data" / "autosave.log").read()


# ---- wrap support ---------------------------------------------------------

def test_unwrapped_lists_raw_play_since_the_last_wrap(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    assert "no unwrapped play" in run(campaign_path, "unwrapped", d, env=e).stdout
    run(campaign_path, "bind", d, env=e)
    t = copy_fixture(tmp_path)
    hook(campaign_path, e, t)
    [f] = raw_files(d)
    p = run(campaign_path, "unwrapped", d, env=e)
    assert p.returncode == 0
    assert f"{f}:1-" in p.stdout  # a never-wrapped file is unwrapped in full

    # the /gm:wrap turn: marked right away (the named checkpoint carries it), then marked
    # again below the wrap turn once the Stop hook has logged it
    append_lines(t, user("<command-name>/gm:wrap</command-name>"))
    p = run(campaign_path, "mark-wrapped", d, "log/0001-the-ledger.md", env=e)
    assert p.returncode == 0
    marker = "<!-- gm:wrapped log/0001-the-ledger.md -->"
    assert marker in open(f).read()
    run(campaign_path, "checkpoint", d, "--label", "the ledger", env=e)
    assert marker in git(d, "show", "HEAD:" + os.path.relpath(f, d))
    append_lines(t, gm("Session logged as 0001-the-ledger."))
    hook(campaign_path, e, t)
    text = open(f).read()
    assert text.count(marker) == 2
    assert text.index(marker) < text.index("Session logged as") < text.rindex(marker)
    assert "no unwrapped play" in run(campaign_path, "unwrapped", d, env=e).stdout
    assert git(d, "show", "HEAD:" + os.path.relpath(f, d)).count(marker) == 2  # committed

    append_lines(t, user("I set out at dawn."), gm("Frost on the road."))
    hook(campaign_path, e, t)
    out = run(campaign_path, "unwrapped", d, env=e).stdout
    start, end = map(int, out.strip().rsplit(":", 1)[1].split("-"))
    lines = open(f).read().splitlines()[start - 1:end]
    body = "\n".join(lines)
    assert "I set out at dawn." in body and "Frost on the road." in body
    assert "Rain hammers" not in body and "gm:wrapped" not in body and "Session logged" not in body


def test_mark_wrapped_marks_immediately_outside_a_bound_session(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    hook(campaign_path, e, copy_fixture(tmp_path))
    other = gm_env(tmp_path)  # e.g. wrapping from a later session with autosave off
    p = run(campaign_path, "mark-wrapped", d, "log/0001-a.md", env=other)
    assert "marked wrapped into log/0001-a.md" in p.stdout
    assert "<!-- gm:wrapped log/0001-a.md -->" in raw_text(d)
    p = run(campaign_path, "mark-wrapped", d, "log/0002-b.md", env=other)
    assert "nothing to mark" in p.stdout
    assert "gm:wrapped log/0002-b.md" not in raw_text(d)


def test_the_wrap_re_mark_only_touches_the_wrapping_sessions_log(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    d = new_campaign(campaign_path, tmp_path, e)
    run(campaign_path, "bind", d, env=e)
    hook(campaign_path, e, copy_fixture(tmp_path))  # an earlier session, never wrapped
    [earlier] = raw_files(d)
    sid2 = "5ec0ad00-0000-4000-8000-000000000002"
    e2 = gm_env(tmp_path, GM_SESSION_ID=sid2)
    run(campaign_path, "bind", d, env=e2)
    t2 = str(tmp_path / "t2.jsonl")
    append_lines(t2, user("<command-name>/gm:play</command-name>"), gm("Where were we?"))
    hook(campaign_path, e2, t2, sid=sid2)
    p = run(campaign_path, "mark-wrapped", d, "log/0001-a.md", env=e2)
    assert os.path.basename(earlier) in p.stdout and "once it's saved" in p.stdout
    [mine] = [f for f in raw_files(d) if f.endswith(f"-{sid2[:8]}.md")]
    assert "gm:wrapped" in open(earlier).read() and "gm:wrapped" in open(mine).read()
    append_lines(t2, user("<command-name>/gm:wrap</command-name>"), gm("Logged."))
    hook(campaign_path, e2, t2, sid=sid2)
    assert open(earlier).read().count("gm:wrapped") == 1
    assert open(mine).read().count("gm:wrapped") == 2


def test_rebinding_elsewhere_drops_a_pending_wrap_re_mark(campaign_path, tmp_path):
    e = gm_env(tmp_path, GM_SESSION_ID=SID)
    a = new_campaign(campaign_path, tmp_path, e, name="a")
    b = new_campaign(campaign_path, tmp_path, e, name="b")
    run(campaign_path, "bind", a, env=e)
    t = str(tmp_path / "t.jsonl")
    append_lines(t, user("<command-name>/gm:play</command-name>"), gm("In A."))
    hook(campaign_path, e, t)
    run(campaign_path, "mark-wrapped", a, "log/0001-a.md", env=e)
    run(campaign_path, "bind", b, env=e)  # same turn: switch campaigns
    append_lines(t, user("<command-name>/gm:play</command-name>"), gm("In B."))
    hook(campaign_path, e, t)
    assert "gm:wrapped" not in raw_text(b)
    assert f"{raw_files(b)[0]}:1-" in run(campaign_path, "unwrapped", b, env=e).stdout


def test_mark_wrapped_matches_a_tilde_path_to_the_binding(campaign_path, tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    e = gm_env(tmp_path, GM_SESSION_ID=SID, HOME=str(home))
    d = new_campaign(campaign_path, home, e, name="ember")
    run(campaign_path, "bind", "~/ember", env=e)  # quoted by the model: no shell expansion
    t = str(tmp_path / "t.jsonl")
    append_lines(t, user("<command-name>/gm:play</command-name>"), gm("The embers glow."))
    hook(campaign_path, e, t)
    assert os.path.join(d, "log", "raw") in run(campaign_path, "unwrapped", "~/ember", env=e).stdout
    p = run(campaign_path, "mark-wrapped", "~/ember", "log/0001-x.md", env=e)
    assert "once it's saved" in p.stdout
    append_lines(t, user("<command-name>/gm:wrap</command-name>"), gm("Logged."))
    hook(campaign_path, e, t)
    assert "no unwrapped play" in run(campaign_path, "unwrapped", "~/ember", env=e).stdout
    assert raw_text(d).count("gm:wrapped log/0001-x.md") == 2


# ---- hooks.json -----------------------------------------------------------

def test_hooks_json_registers_fail_safe_commands(campaign_path, tmp_path):
    hooks = json.load(open(HOOKS_JSON))["hooks"]
    assert set(hooks) == {"SessionStart", "PostToolUse", "Stop", "SessionEnd"}
    plugin_root = os.path.abspath(os.path.join(HERE, ".."))
    e = gm_env(tmp_path, CLAUDE_PLUGIN_ROOT=plugin_root)
    for event, groups in hooks.items():
        for group in groups:
            for h in group["hooks"]:
                cmd = h["command"]
                assert "${CLAUDE_PLUGIN_ROOT}" in cmd
                # garbage input through the real command line still exits 0 (never blocks)
                p = subprocess.run(["sh", "-c", cmd], input="garbage", capture_output=True,
                                   text=True, env=e)
                assert p.returncode == 0, (event, cmd, p.stderr)
