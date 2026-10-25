import json
from datetime import UTC, date, datetime, timedelta
from pathlib import Path

from kb.extract import clean, extract_day, read_session

DAY = date(2026, 10, 22)
TZ = datetime.now().astimezone().tzinfo


def stamp(hour: int, day: date = DAY) -> str:
    local = datetime.combine(day, datetime.min.time(), TZ) + timedelta(hours=hour)
    return local.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def line(kind: str, content, hour: int = 10, **extra) -> str:
    record = {
        "type": kind,
        "message": {"role": kind, "content": content},
        "cwd": "/home/me/dev/my-app",
        "gitBranch": "feat/kb",
        "timestamp": stamp(hour),
        "entrypoint": "cli",
        "version": "2.1.309",
        **extra,
    }
    return json.dumps(record)


def write_transcript(projects: Path, session: str, lines: list[str]) -> Path:
    folder = projects / "-home-me-dev-my-app"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{session}.jsonl"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def test_extract_day_keeps_dialogue_and_drops_tool_output(tmp_path: Path):
    projects = tmp_path / "projects"
    lines = [
        json.dumps({"type": "ai-title", "aiTitle": "Build the knowledge base"}),
        line("user", "Ajoute un index SQLite, token ghp_abcdefghijklmnop1234 à ne pas garder"),
        line(
            "assistant",
            [
                {"type": "text", "text": "I will add it."},
                {
                    "type": "tool_use",
                    "name": "Edit",
                    "input": {"file_path": "/home/me/dev/my-app/kb/index.py"},
                },
                {"type": "tool_use", "name": "Read", "input": {"file_path": "/x"}},
            ],
            hour=10,
        ),
        line(
            "user",
            [{"type": "tool_result", "tool_use_id": "1", "content": "huge output " * 1000}],
            hour=10,
        ),
        line("assistant", [{"type": "text", "text": "Done, see [the file]."}], hour=11),
        line("user", "<system-reminder>injected</system-reminder>merci", hour=11),
        line("user", "sidechain noise", hour=11, isSidechain=True),
        line("user", "yesterday's message", hour=-5),
        json.dumps(
            {"type": "pr-link", "prRepository": "someone/my-app", "prNumber": 12}
        ),
    ]
    write_transcript(projects, "abcdef12-0000", lines)
    out = tmp_path / "out"
    summary = extract_day(DAY, projects, out, dev_root=Path("/home/me/dev"))

    assert len(summary.sessions) == 1
    session = summary.sessions[0]
    assert session.repo == "my-app"
    assert session.title == "Build the knowledge base"
    assert session.user_messages == 2
    assert session.assistant_messages == 2
    assert session.tool_results == 1
    assert session.files_edited == ["/home/me/dev/my-app/kb/index.py"]
    assert session.prs == ["someone/my-app#12"]
    assert dict(session.tools) == {"Edit": 1, "Read": 1}

    text = (summary.out_dir / "my-app--abcdef12.md").read_text()
    assert "ghp___SECRET__" in text
    assert "ghp_abcdefghijklmnop1234" not in text
    assert "huge output" not in text
    assert "injected" not in text
    assert "sidechain noise" not in text
    assert "yesterday's message" not in text
    assert "**User (11:00):** merci" in text
    assert "_[tools: Edit, Read]_" in text
    index = (summary.out_dir / "index.md").read_text()
    assert "1 sessions in 1 repositories: my-app (1)" in index
    assert "PRs someone/my-app#12" in index


def test_scripted_sessions_and_empty_days_are_skipped(tmp_path: Path):
    projects = tmp_path / "projects"
    write_transcript(projects, "sdk", [line("user", "automated", entrypoint="sdk-py")])
    summary = extract_day(DAY, projects, tmp_path / "out", dev_root=Path("/home/me/dev"))
    assert summary.sessions == []
    assert "No session that day." in (summary.out_dir / "index.md").read_text()


def test_read_session_outside_dev_root_uses_last_folders(tmp_path: Path):
    projects = tmp_path / "projects"
    path = write_transcript(projects, "s1", [line("user", "hi", cwd="/Users/me/Documents/Code")])
    start = datetime.combine(DAY, datetime.min.time(), TZ)
    session = read_session(path, start, start + timedelta(days=1), Path("/elsewhere"))
    assert session is not None
    assert session.repo == "Documents/Code"
    path = write_transcript(projects, "s2", [line("user", "hi", cwd="/home/me/dev")])
    session = read_session(path, start, start + timedelta(days=1), Path("/home/me/dev"))
    assert session is not None and session.repo == "dev"


def test_config_sync_log_keeps_meaningful_files_only(tmp_path: Path):
    import shutil
    import subprocess

    from kb.extract import config_sync_log

    repo = tmp_path / "sync"
    repo.mkdir()
    env = {
        "GIT_AUTHOR_DATE": f"{DAY.isoformat()}T10:00:00",
        "GIT_COMMITTER_DATE": f"{DAY.isoformat()}T10:00:00",
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@t",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t",
        "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin",
    }

    git_bin = shutil.which("git") or "git"

    def git(*args: str) -> None:
        subprocess.run(  # noqa: S603
            [git_bin, "-C", str(repo), *args], check=True, env=env, capture_output=True
        )

    git("init", "-q")
    (repo / "reminders").mkdir()
    (repo / "pr-watch").mkdir()
    (repo / "reminders" / "2026-10-22-call-lea.md").write_text("call")
    (repo / "pr-watch" / "builds.json").write_text("{}")
    project = repo / "repos" / "github.com" / "someone" / "my-app"
    (project / ".claude").mkdir(parents=True)
    (project / "CLAUDE.md").write_text("rules")
    (project / ".claude" / "publish-state.json").write_text("{}")
    git("add", "-A")
    git("commit", "-q", "-m", "chore(sync): update from mac")
    (repo / "assistant").mkdir()
    (repo / "assistant" / "memory.md").write_text("fact")
    git("add", "-A")
    git("commit", "-q", "-m", "chore(sync): the assistant remembers a fact")

    text = config_sync_log(DAY, repo)
    assert "added reminders/2026-10-22-call-lea.md" in text
    assert "added repos/github.com/someone/my-app/CLAUDE.md" in text
    assert "publish-state" not in text
    assert "assistant/memory.md" not in text
    assert "the assistant remembers a fact" in text
    assert "pr-watch" not in text
    assert config_sync_log(DAY + timedelta(days=3), repo) == ""
    assert config_sync_log(DAY, tmp_path / "nope") == ""


def test_clean_truncates_and_redacts():
    assert clean("password=hunter2secret rest") == "password=__SECRET__ rest"
    assert clean("Authorization: Bearer abcdefghijklmnopqrstuvwxyz") == "Authorization: __SECRET__"
    assert clean('"token": "abcdefgh1234"') == '"token": "__SECRET__"'
    assert clean("API_KEY = 'xyzxyzxyz'") == "API_KEY = '__SECRET__'"
    assert (
        clean("run it with --password hunter2secret now") == "run it with --password __SECRET__ now"
    )
    assert clean("--token=abcdefgh1234") == "--token=__SECRET__"
    assert clean("the token expires tomorrow") == "the token expires tomorrow"
    long = clean("a" * 5000)
    assert long.endswith(" […]") and len(long) < 3100
