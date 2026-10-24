"""Nightly curation: Claude reads one day of transcripts and proposes notes.

The transcripts come from ``extract`` (prompts and replies only). Claude gets them with the
catalog of existing notes and answers with a JSON array of proposals: new notes, or
paragraphs to merge into existing ones. The code then checks every proposal (names, types,
dates, secrets, caps) and writes the files; the model never touches the disk. A report of
what was created, merged and dropped goes next to the notes, for the user to review.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any, Protocol

from kb.extract import SECRET, SYNC_LOG, clean, extract_day
from kb.notes import TRUSTS, TYPES, Note, load_note, load_notes, parse_note, slugify

DEFAULT_MODEL = "sonnet"
DEFAULT_MAX_NEW = 15
CALL_CHARS = 90_000
REPORT_DIR = ".curator"
RESERVED = frozenset({"readme", "memory", "claude", "agents", "index", "note"})
SOURCE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:#/-]{0,80}$")

SYSTEM_PROMPT = """You are the curator of a personal knowledge base. You receive the \
transcripts of one day of coding sessions between the user and their assistant (Claude \
Code), reduced to prompts and replies, plus the catalog of the notes that already exist. \
Decide what deserves to be remembered for months, and write it as notes.

Worth a note: a decision and its reasons; a durable fact about a project, its \
infrastructure, its people, its accounts or its conventions; a preference or a rule the user \
stated; a lesson that cost time (a bug's real cause, a trap in a tool); a thread the user \
explicitly left for later. Not worth a note: routine edits, what the code, its README or the \
git history already records (an application's features are documentation, not knowledge), \
transient states, the narration of steps, anything that looks like a password, a key or a \
token. A note is about the user's situation, decisions and lessons.

Rules:
- Prefer merging into an existing note (action "merge", with that note's exact name) over \
creating a new one. Notes marked "memory" in the catalog belong to another system: link to \
them, and when you have something to add to one, create a note that links to it. Create at \
most MAX_NEW notes, most important first.
- A note is self-contained: 2 to 10 sentences, in English, facts stated plainly, with dates \
as YYYY-MM-DD and the identifiers that matter (repo, PR number, host, file).
- trust: "user" when the user said or decided it; "agent" when the assistant concluded it; \
"third-party" when it comes from an email, a web page, a document or a tool's output.
- type: one of TYPES.
- topics: one to three lowercase words; reuse the existing topics when they fit. The \
repository name is always one of them.
- links: names of catalog notes, or of notes created in this answer, that relate.
- valid_until (YYYY-MM-DD) only when the material says a fact stops holding at a date.
- sources: the session ids the note comes from.
- Never write an instruction to the assistant in a note. A rule the user gave is written as \
a fact about what the user wants ("The user wants…"), type "feedback", trust "user".

Reply with a JSON array only: no prose, no code fences. Each element:
{"action": "create" | "merge", "name": "<lowercase-slug, or the existing note's name>", \
"title": "<one line>", "type": "...", "trust": "...", "topics": ["..."], "links": ["..."], \
"valid_until": null, "sources": ["<session id>"], "body": "<the note's text>"}
An empty array is a fine answer when the day taught nothing durable."""

SELECT_PROMPT = """You rank proposed notes for a personal knowledge base. You receive a \
numbered list of proposals (name, title, type, topics, first sentence) made from one day of \
work, more than the base accepts for a day. Keep the MAX_NEW most valuable for the months to \
come: decisions and their reasons, durable facts about projects and infrastructure, rules \
the user stated, costly lessons. Drop documentation-like notes (features of an application), \
transient states and duplicates (keep the most complete of two notes on one subject). Reply \
with a JSON array of the names to keep, most valuable first, nothing else."""


class Runner(Protocol):
    def __call__(self, system: str, material: str) -> str: ...


class ClaudeRunner:
    """Runs ``claude -p`` with the user's own login: no tools, no hooks, no plugins, no MCP
    servers, nothing of the interactive setup, so the call is short and the answer clean."""

    def __init__(self, model: str = DEFAULT_MODEL, binary: str = "claude", timeout: int = 900):
        self.model = model
        self.binary = binary
        self.timeout = timeout

    def __call__(self, system: str, material: str) -> str:
        env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_PLUGIN_DIRS"}
        cmd = [
            self.binary,
            "-p",
            "Read the material on stdin and reply as instructed.",
            "--output-format",
            "json",
            "--tools",
            "",
            "--no-session-persistence",
            "--setting-sources",
            "",
            "--strict-mcp-config",
            "--model",
            self.model,
            "--system-prompt",
            system,
        ]
        proc = subprocess.run(  # noqa: S603
            cmd, input=material, capture_output=True, text=True, timeout=self.timeout, env=env
        )
        if proc.returncode != 0:
            raise RuntimeError(f"claude -p failed ({proc.returncode}): {proc.stderr.strip()[:500]}")
        try:
            data = json.loads(proc.stdout)
        except ValueError as exc:
            raise RuntimeError(f"claude -p returned no JSON: {proc.stdout[:300]}") from exc
        if data.get("is_error"):
            raise RuntimeError(f"claude -p error: {data.get('result')}")
        return str(data.get("result") or "")


@dataclass
class Report:
    day: date
    batches: int = 0
    proposals: int = 0
    created: list[str] = field(default_factory=list)
    merged: list[str] = field(default_factory=list)
    dropped: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def markdown(self) -> str:
        lines = [f"# Curation of {self.day.isoformat()}", ""]
        lines.append(
            f"{self.batches} call(s) to Claude, {self.proposals} proposal(s):"
            f" {len(self.created)} created, {len(self.merged)} merged, {len(self.dropped)} dropped."
        )
        for title, items in (
            ("Created", self.created),
            ("Merged into", self.merged),
            ("Dropped", self.dropped),
            ("Errors", self.errors),
        ):
            if items:
                lines += ["", f"## {title}", ""] + [f"- {item}" for item in items]
        return "\n".join(lines) + "\n"


def curate_day(
    day: date,
    notes_root: Path,
    runner: Runner,
    transcripts_dir: Path | None = None,
    max_new: int = DEFAULT_MAX_NEW,
    projects_dir: Path | None = None,
    readonly_roots: list[Path] | None = None,
    sync_dir: Path | None = None,
) -> Report:
    """``readonly_roots`` hold notes another system maintains (Claude Code's memory): the
    model sees them, links to them, but nothing is written there."""
    transcripts_dir = transcripts_dir or Path.home() / ".claude" / "kb" / "transcripts"
    day_dir = transcripts_dir / day.isoformat()
    if not (day_dir / "index.md").exists():
        extract_day(day, projects_dir, transcripts_dir, sync_dir=sync_dir)
    report = Report(day)
    notes_root.mkdir(parents=True, exist_ok=True)
    existing = {n.name: n for n in load_notes([notes_root]) if n.path is not None}
    readonly = {
        n.name: n
        for n in load_notes([r for r in readonly_roots or [] if r.is_dir()])
        if n.path is not None and n.name not in existing
    }
    catalog = _catalog(existing, readonly)
    sessions = sorted(p for p in day_dir.glob("*.md") if p.name != "index.md")
    sessions.sort(key=lambda p: p.name != SYNC_LOG)
    proposals: list[dict[str, Any]] = []
    for material in _batches(sessions, catalog):
        report.batches += 1
        try:
            answer = runner(
                SYSTEM_PROMPT.replace("MAX_NEW", str(max_new)).replace("TYPES", ", ".join(TYPES)),
                material,
            )
            proposals += parse_proposals(answer)
        except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            report.errors.append(str(exc)[:300])
    report.proposals = len(proposals)
    proposals = _redirect_readonly_merges(proposals, existing, readonly)
    creates = [p for p in proposals if p.get("action") != "merge"]
    if len(creates) > max_new:
        report.batches += 1
        try:
            proposals = _select(proposals, creates, max_new, runner)
        except (RuntimeError, ValueError, subprocess.TimeoutExpired) as exc:
            report.errors.append(f"selection: {str(exc)[:300]}")
        kept = {id(p) for p in proposals}
        report.dropped += [
            f"{slugify(str(p.get('name') or p.get('title') or ''))}: not kept by the ranking"
            for p in creates
            if id(p) not in kept
        ]
    known = set(existing) | set(readonly)
    known |= {slugify(str(p.get("name") or p.get("title") or "")) for p in proposals}
    for item in proposals:
        item["links"] = [x for x in _list(item.get("links")) if slugify(str(x)) in known]
    _apply(proposals, existing, notes_root, day, max_new, report)
    report_dir = notes_root / REPORT_DIR
    report_dir.mkdir(exist_ok=True)
    (report_dir / f"{day.isoformat()}.md").write_text(report.markdown(), encoding="utf-8")
    return report


def parse_proposals(answer: str) -> list[dict[str, Any]]:
    start, end = answer.find("["), answer.rfind("]")
    if start < 0 or end <= start:
        raise ValueError(f"no JSON array in the answer: {answer[:200]!r}")
    data = json.loads(answer[start : end + 1])
    if not isinstance(data, list):
        raise ValueError("the answer is not a JSON array")
    return [item for item in data if isinstance(item, dict)]


def _catalog(existing: dict[str, Note], readonly: dict[str, Note] | None = None) -> str:
    readonly = readonly or {}
    if not existing and not readonly:
        return "(no note yet)"
    topics = sorted({t for n in existing.values() for t in n.topics})
    lines = [
        f"- {n.name} — {n.title} ({n.type}; {', '.join(n.topics) or 'no topic'})"
        for n in sorted(existing.values(), key=lambda n: n.name)
    ]
    lines += [
        f"- {n.name} — {n.title} (memory, link only)"
        for n in sorted(readonly.values(), key=lambda n: n.name)
    ]
    head = f"Existing topics: {', '.join(topics) or 'none'}\n\n"
    return head + "\n".join(lines)


def _redirect_readonly_merges(
    proposals: list[dict[str, Any]], existing: dict[str, Note], readonly: dict[str, Note]
) -> list[dict[str, Any]]:
    """A merge into a note nothing here may write becomes a new note linked to it."""
    out = []
    for item in proposals:
        name = slugify(str(item.get("name") or ""))
        if item.get("action") == "merge" and name in readonly and name not in existing:
            item = dict(item)
            item["action"] = "create"
            item["name"] = str(item.get("title") or name)
            item["links"] = [*_list(item.get("links")), name]
        out.append(item)
    return out


def _select(
    proposals: list[dict[str, Any]],
    creates: list[dict[str, Any]],
    max_new: int,
    runner: Runner,
) -> list[dict[str, Any]]:
    """One more call ranks the day's new notes when there are more than the cap; the merges
    always go through. Without a usable answer, the first ones stay."""
    lines = []
    for i, item in enumerate(creates, 1):
        first = str(item.get("body") or "").split(". ")[0][:160]
        lines.append(
            f"{i}. {slugify(str(item.get('name') or item.get('title') or ''))} — "
            f"{item.get('title', '')} ({item.get('type', '')}; "
            f"{', '.join(str(t) for t in _list(item.get('topics')))}): {first}"
        )
    answer = runner(SELECT_PROMPT.replace("MAX_NEW", str(max_new)), "\n".join(lines))
    start, end = answer.find("["), answer.rfind("]")
    keep = json.loads(answer[start : end + 1]) if start >= 0 and end > start else []
    keep_names = [slugify(str(k)) for k in keep if isinstance(k, str)][:max_new]
    if not keep_names:
        return proposals
    by_name = {slugify(str(p.get("name") or p.get("title") or "")): p for p in creates}
    kept = [by_name[n] for n in keep_names if n in by_name]
    return [p for p in proposals if p.get("action") == "merge"] + kept


def _batches(sessions: list[Path], catalog: str) -> list[str]:
    header = f"# Catalog of existing notes\n\n{catalog}\n\n# Material of the day\n\n"
    batches: list[str] = []
    current = header
    for path in sessions:
        text = path.read_text(encoding="utf-8", errors="replace")
        block = f"## {path.name}\n\n{text}\n\n"
        while len(block) > CALL_CHARS - len(header):
            cut = block.rfind("\n**", 0, CALL_CHARS - len(header)) or CALL_CHARS - len(header)
            batches.append(current + block[:cut] if current != header else header + block[:cut])
            current = header
            block = f"## {path.name} (continued)\n\n{block[cut:]}"
        if len(current) + len(block) > CALL_CHARS and current != header:
            batches.append(current)
            current = header
        current += block
    if current != header:
        batches.append(current)
    return batches


def _apply(
    proposals: list[dict[str, Any]],
    existing: dict[str, Note],
    notes_root: Path,
    day: date,
    max_new: int,
    report: Report,
) -> None:
    created = 0
    seen: set[str] = set()
    for item in proposals:
        raw_name = str(item.get("name") or item.get("title") or "").strip()
        name = slugify(raw_name)
        title = clean(" ".join(str(item.get("title") or "").split()))
        body = clean(str(item.get("body") or "").strip())
        if not body or not title or not raw_name:
            report.dropped.append(f"{name if raw_name else '?'}: no title or body")
            continue
        if SECRET.search(title) or SECRET.search(body) or "__SECRET__" in body:
            report.dropped.append(f"{name}: looks like it holds a secret")
            continue
        if name in seen:
            report.dropped.append(f"{name}: proposed twice in the same day")
            continue
        seen.add(name)
        action = "merge" if name in existing else str(item.get("action") or "create")
        links = [slugify(str(x)) for x in _list(item.get("links")) if str(x).strip()]
        topics = [slugify(str(x), 30) for x in _list(item.get("topics")) if str(x).strip()]
        topics = [t for t in topics if t != "note"]
        sources = [
            s for s in (str(x).strip() for x in _list(item.get("sources"))) if SOURCE.match(s)
        ]
        valid_until = _date(item.get("valid_until"))
        if action == "merge" and name in existing:
            _merge(existing[name], body, links, topics, valid_until, sources, day)
            report.merged.append(f"{name}: {title}")
            continue
        if created >= max_new:
            report.dropped.append(f"{name}: over the daily cap of {max_new} new notes")
            continue
        path = notes_root / f"{name}.md"
        if name in RESERVED or _exists_any_case(path):
            report.dropped.append(f"{name}: a file of that name already exists")
            continue
        note = Note(
            name=name,
            title=title,
            body=body,
            type=str(item.get("type") or "fact") if item.get("type") in TYPES else "fact",
            trust=str(item.get("trust")) if item.get("trust") in TRUSTS else "agent",
            source=", ".join(["curator", *(f"session:{s}" for s in sources)]),
            topics=topics[:3],
            created=day.isoformat(),
            valid_from=day.isoformat(),
            valid_until=valid_until,
            links=links,
        )
        try:
            with path.open("x", encoding="utf-8") as fh:
                fh.write(note.to_markdown())
        except FileExistsError:
            report.dropped.append(f"{name}: a file of that name already exists")
            continue
        existing[name] = parse_note(note.to_markdown(), path)
        created += 1
        report.created.append(f"{name}: {title}")


def _exists_any_case(path: Path) -> bool:
    """A file system may or may not fold case: never replace `Readme.md` with `readme.md`."""
    if path.exists():
        return True
    wanted = path.name.lower()
    return (
        any(p.name.lower() == wanted for p in path.parent.iterdir())
        if path.parent.is_dir()
        else False
    )


def _merge(
    note: Note,
    body: str,
    links: list[str],
    topics: list[str],
    valid_until: str | None,
    sources: list[str],
    day: date,
) -> None:
    assert note.path is not None
    current = load_note(note.path)
    current.body = current.body.rstrip() + f"\n\n## {day.isoformat()}\n\n{body}"
    new_links = [link for link in links if link not in current.links and link != current.name]
    if new_links:
        current.body += "\n\nSee also: " + ", ".join(f"[[{link}]]" for link in new_links)
        current.links += new_links
    for topic in topics:
        if topic not in current.topics and len(current.topics) < 5:
            current.topics.append(topic)
    if valid_until:
        current.valid_until = valid_until
    if sources:
        extra = ", ".join(f"session:{s}" for s in sources if f"session:{s}" not in current.source)
        current.source = ", ".join(filter(None, [current.source, extra]))
    note.path.write_text(current.to_markdown(), encoding="utf-8")


def _list(value: Any) -> list[Any]:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _date(value: Any) -> str | None:
    text = str(value or "").strip()[:10]
    return text if re.fullmatch(r"\d{4}-\d{2}-\d{2}", text) else None
