"""One day of Claude Code transcripts, reduced to what a reader needs.

Transcripts hold every tool call and its output; a day of them weighs a hundred megabytes.
This keeps the user's prompts, the assistant's replies, which tools ran, which files were
edited and which pull requests came up, as one Markdown file per session. Tool output is
dropped, and anything that looks like a secret is replaced before it is written.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from collections import Counter
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from kb.notes import slugify

MAX_MESSAGE_CHARS = 3000
EDIT_TOOLS = {"Edit", "Write", "MultiEdit", "NotebookEdit"}
SYNC_LOG = "config-sync.md"
# Folders of the config sync whose changes mean something happened to the user: reminders
# left or closed, handoffs, notes, config, every repo's agent docs, plus the "syncFolders" of
# kb.json in the sync repo (an assistant's own folder), the same for every computer. State files,
# PR-watch snapshots and inventories are machine noise.
SYNC_FOLDERS = ("reminders/", "handoffs/", "knowledge/", "memory", "mcp/")
SYNC_FILES = re.compile(
    r"^(claude/(CLAUDE\.md|skills/[^/]+/SKILL\.md)"
    r"|(repos|folders)/.+/((CLAUDE|CLAUDE\.local|AGENTS)\.md|\.claude/.+\.md))$"
)
MAX_SYNC_LINES = 150
SECRET = re.compile(
    r"(?P<p1>ghp_|gho_|github_pat_|sk-ant-[a-z0-9-]*|sk-[A-Za-z0-9]{2,}-|AKIA|xox[abp]-)"
    r"[A-Za-z0-9_\-]{8,}"
    r"|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"
    r"|(?i:bearer)\s+[A-Za-z0-9._\-]{16,}"
    r"|(?P<p2>[\"']?(?i:password|passwd|secret|token|api[_-]?key)[\"']?\s*[=:]\s*[\"']?)"
    r"[^\s\"']{6,}"
    r"|(?P<p3>--(?i:password|passwd|secret|token|api[_-]?key)[= ]\s*[\"']?)[^\s\"']{6,}"
)
INJECTED = re.compile(
    r"<(system-reminder|local-command-caveat|local-command-stdout|command-name|command-message"
    r"|command-args|task-notification|pasted_content[^>]*)>[\s\S]*?</\1>"
    r"|<pasted_content[^>]*/>",
)


@dataclass
class Session:
    id: str
    repo: str
    branch: str | None
    title: str | None
    started: datetime | None
    ended: datetime | None
    turns: list[dict[str, Any]] = field(default_factory=list)
    tools: Counter = field(default_factory=Counter)
    files_edited: list[str] = field(default_factory=list)
    prs: list[str] = field(default_factory=list)
    user_messages: int = 0
    assistant_messages: int = 0
    tool_results: int = 0
    raw_bytes: int = 0
    version: str | None = None


@dataclass
class DaySummary:
    day: date
    sessions: list[Session]
    raw_bytes: int
    written_bytes: int
    out_dir: Path


def extract_day(
    day: date,
    projects_dir: Path | None = None,
    out_dir: Path | None = None,
    dev_root: Path | None = None,
    sync_dir: Path | None = None,
) -> DaySummary:
    projects_dir = projects_dir or Path.home() / ".claude" / "projects"
    out_dir = (out_dir or Path.home() / ".claude" / "kb" / "transcripts") / day.isoformat()
    sync_dir = sync_dir or Path.home() / ".claude-sync"
    dev_root = dev_root or Path(os.environ.get("CLAUDE_DEV_ROOT") or Path.home() / "dev")
    tz = datetime.now().astimezone().tzinfo
    start = datetime.combine(day, datetime.min.time(), tz)
    end = start + timedelta(days=1)

    sessions: list[Session] = []
    raw_total = 0
    for path in sorted(projects_dir.glob("*/*.jsonl")):
        if path.stat().st_mtime < start.timestamp():
            continue
        raw_total += path.stat().st_size
        session = read_session(path, start, end, dev_root)
        if session is not None and session.turns:
            sessions.append(session)
    sessions.sort(key=lambda s: (s.repo, s.started or start))

    out_dir.mkdir(parents=True, exist_ok=True)
    written = 0
    for session in sessions:
        text = render_session(session)
        target = out_dir / f"{slugify(session.repo, 40)}--{session.id[:8]}.md"
        target.write_text(text, encoding="utf-8")
        written += len(text.encode("utf-8"))
    index = render_index(day, sessions)
    (out_dir / "index.md").write_text(index, encoding="utf-8")
    written += len(index.encode("utf-8"))
    sync_log = config_sync_log(day, sync_dir)
    if sync_log:
        (out_dir / SYNC_LOG).write_text(sync_log, encoding="utf-8")
        written += len(sync_log.encode("utf-8"))
    return DaySummary(day, sessions, raw_total, written, out_dir)


def shared_sync_folders(sync_dir: Path) -> tuple[str, ...]:
    try:
        listed = json.loads((sync_dir / "kb.json").read_text(encoding="utf-8")).get("syncFolders")
    except (OSError, ValueError, AttributeError):
        return ()
    if not isinstance(listed, list):
        return ()
    return tuple(f.strip("/") + "/" for f in listed if isinstance(f, str) and f.strip("/"))


def config_sync_log(day: date, sync_dir: Path) -> str:
    """What the config sync repo recorded that day, as a reader would want it: time,
    computer, change and file, for the folders that carry meaning."""
    git = shutil.which("git")
    if git is None or not (sync_dir / ".git").exists():
        return ""
    start = day.isoformat()
    end = (day + timedelta(days=1)).isoformat()
    try:
        proc = subprocess.run(  # noqa: S603
            [
                git,
                "-C",
                str(sync_dir),
                "log",
                f"--since={start} 00:00",
                f"--until={end} 00:00",
                "--date=format:%H:%M",
                "--format=@%ad %s",
                "--name-status",
            ],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    folders = SYNC_FOLDERS + shared_sync_folders(sync_dir)
    lines: list[str] = []
    stamp = ""
    for raw in proc.stdout.splitlines():
        if raw.startswith("@"):
            when, _, message = raw[1:].partition(" ")
            origin = message.rsplit(" from ", 1)[-1] if " from " in message else ""
            stamp = f"{when} {origin}".rstrip()
            if not message.startswith("chore(sync): update"):
                lines.append(f"- {stamp}: {message}")
            continue
        parts = raw.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0][:1], parts[-1]
        if not (path.startswith(folders) or SYNC_FILES.match(path)):
            continue
        verb = {"A": "added", "D": "removed", "M": "changed", "R": "renamed"}.get(status, status)
        lines.append(f"- {stamp}: {verb} {path}")
    lines = list(dict.fromkeys(reversed(lines)))
    if not lines:
        return ""
    if len(lines) > MAX_SYNC_LINES:
        lines = lines[:MAX_SYNC_LINES] + [f"- … {len(lines) - MAX_SYNC_LINES} more"]
    return (
        f"# Config sync changes of {start}\n\nFiles the computers and the home agent changed in"
        " the shared config repo (reminders, handoffs, tasks, memory, notes, config), oldest"
        " first.\n\n" + "\n".join(lines) + "\n"
    )


def read_session(path: Path, start: datetime, end: datetime, dev_root: Path) -> Session | None:
    session = Session(path.stem, "", None, None, None, None, raw_bytes=path.stat().st_size)
    cwd: str | None = None
    entrypoint: str | None = None
    with path.open(encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try:
                record = json.loads(line)
            except ValueError:
                continue
            kind = record.get("type")
            if kind == "ai-title" and record.get("aiTitle"):
                session.title = session.title or record["aiTitle"]
            elif kind == "custom-title" and record.get("customTitle"):
                session.title = record["customTitle"]
            elif kind == "pr-link":
                pr = f"{record.get('prRepository', '')}#{record.get('prNumber', '')}"
                if pr not in session.prs:
                    session.prs.append(pr)
            if kind not in ("user", "assistant"):
                continue
            if record.get("isSidechain") or record.get("isMeta"):
                continue
            entrypoint = entrypoint or record.get("entrypoint")
            cwd = cwd or record.get("cwd")
            session.branch = record.get("gitBranch") or session.branch
            session.version = record.get("version") or session.version
            stamp = _timestamp(record.get("timestamp"))
            if stamp is None or not (start <= stamp < end):
                continue
            session.started = min(session.started or stamp, stamp)
            session.ended = max(session.ended or stamp, stamp)
            _add_turn(session, kind, record.get("message") or {}, stamp)
    if entrypoint not in (None, "cli", "claude-desktop", "sdk-cli"):
        return None
    session.repo = _repo_label(cwd, path.parent.name, dev_root)
    return session


def _add_turn(session: Session, kind: str, message: dict[str, Any], stamp: datetime) -> None:
    content = message.get("content")
    blocks = [{"type": "text", "text": content}] if isinstance(content, str) else content or []
    texts: list[str] = []
    tools: list[str] = []
    for block in blocks:
        if not isinstance(block, dict):
            continue
        btype = block.get("type")
        if btype == "text" and block.get("text"):
            texts.append(block["text"])
        elif btype == "tool_use":
            name = str(block.get("name") or "tool")
            tools.append(name)
            session.tools[name] += 1
            if name in EDIT_TOOLS:
                target = str((block.get("input") or {}).get("file_path") or "")
                if target and target not in session.files_edited:
                    session.files_edited.append(target)
        elif btype == "tool_result":
            session.tool_results += 1
    text = clean("\n".join(texts))
    if kind == "user":
        if not text:
            return
        session.user_messages += 1
    else:
        if not text and not tools:
            return
        session.assistant_messages += 1
    session.turns.append({"role": kind, "at": stamp, "text": text, "tools": tools})


def clean(text: str) -> str:
    text = INJECTED.sub("", text)
    text = SECRET.sub(
        lambda m: (m.group("p1") or m.group("p2") or m.group("p3") or "") + "__SECRET__", text
    )
    text = text.strip()
    if len(text) > MAX_MESSAGE_CHARS:
        text = text[:MAX_MESSAGE_CHARS].rstrip() + " […]"
    return text


def render_session(session: Session) -> str:
    lines = [
        "---",
        f"session: {session.id}",
        f"repo: {session.repo}",
        f"branch: {session.branch or ''}",
        f'title: "{(session.title or "").replace(chr(34), "")}"',
        f"started: {_fmt(session.started)}",
        f"ended: {_fmt(session.ended)}",
        f"messages: {session.user_messages} user, {session.assistant_messages} assistant,"
        f" {session.tool_results} tool results",
        f"files_edited: [{', '.join(session.files_edited)}]",
        f"prs: [{', '.join(session.prs)}]",
        "---",
        "",
    ]
    last_tools: list[str] = []
    for turn in session.turns:
        if turn["role"] == "assistant" and turn["tools"] and not turn["text"]:
            last_tools.extend(turn["tools"])
            continue
        if last_tools:
            lines.append(f"_[tools: {_fold(last_tools)}]_")
            lines.append("")
            last_tools = []
        who = "User" if turn["role"] == "user" else "Assistant"
        lines.append(f"**{who} ({turn['at'].strftime('%H:%M')}):** {turn['text']}")
        if turn["role"] == "assistant" and turn["tools"]:
            lines.append(f"_[tools: {_fold(turn['tools'])}]_")
        lines.append("")
    if last_tools:
        lines.append(f"_[tools: {_fold(last_tools)}]_")
        lines.append("")
    return "\n".join(lines)


def render_index(day: date, sessions: list[Session]) -> str:
    lines = [f"# Claude Code sessions of {day.isoformat()}", ""]
    if not sessions:
        lines.append("No session that day.")
        return "\n".join(lines) + "\n"
    repos = Counter(s.repo for s in sessions)
    lines.append(
        f"{len(sessions)} sessions in {len(repos)} repositories: "
        + ", ".join(f"{repo} ({n})" for repo, n in repos.most_common())
    )
    lines.append("")
    for session in sessions:
        when = f"{_fmt(session.started, '%H:%M')}–{_fmt(session.ended, '%H:%M')}"
        title = session.title or "(no title)"
        extra = []
        if session.branch and session.branch not in ("main", "master", "HEAD"):
            extra.append(f"branch {session.branch}")
        if session.files_edited:
            extra.append(f"{len(session.files_edited)} files edited")
        if session.prs:
            extra.append("PRs " + ", ".join(session.prs))
        lines.append(
            f"- {when} · {session.repo} · {title} · {session.user_messages} prompts"
            + (" · " + ", ".join(extra) if extra else "")
            + f" · `{slugify(session.repo, 40)}--{session.id[:8]}.md`"
        )
    return "\n".join(lines) + "\n"


def _fold(tools: list[str]) -> str:
    counts = Counter(tools)
    return ", ".join(f"{name}×{n}" if n > 1 else name for name, n in counts.most_common())


def _fmt(stamp: datetime | None, pattern: str = "%Y-%m-%d %H:%M") -> str:
    return stamp.strftime(pattern) if stamp else ""


def _timestamp(value: Any) -> datetime | None:
    if not isinstance(value, str):
        return None
    try:
        stamp = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return stamp.astimezone()


def _repo_label(cwd: str | None, project_dir: str, dev_root: Path) -> str:
    if cwd:
        cwd_path = Path(cwd)
        try:
            label = cwd_path.resolve().relative_to(dev_root.resolve()).as_posix()
            label = label.replace("/.claude/worktrees/", "@")
            return dev_root.name if label in ("", ".") else label
        except (ValueError, OSError):
            return "/".join(cwd_path.parts[-2:]) if len(cwd_path.parts) >= 2 else cwd
    return project_dir.strip("-").replace("-", "/")
