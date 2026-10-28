"""Notes: one Markdown file per piece of knowledge, a front matter and ``[[links]]``.

The front matter is a small subset of YAML, read without a dependency: ``key: value``,
inline lists ``[a, b]``, block lists and one level of nested mapping. Claude Code's memory
files (``name``, ``description``, ``metadata.type``) read as notes without any change.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

FRONT_MATTER = re.compile(r"\A---\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n|\Z)", re.S)
WIKILINK = re.compile(r"\[\[([^\]|#]+)(?:[#|][^\]]*)?\]\]")
HEADING = re.compile(r"^#\s+(.+?)\s*$", re.M)
NAME = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
TYPES = (
    "fact",
    "decision",
    "howto",
    "reference",
    "event",
    "person",
    "project",
    "feedback",
    "user",
)
TRUSTS = ("user", "agent", "third-party")
SKIPPED_FILES = {"MEMORY.md", "README.md", "AGENTS.md", "CLAUDE.md"}


@dataclass
class Note:
    name: str
    title: str
    body: str
    type: str = "fact"
    trust: str = "agent"
    source: str = ""
    topics: list[str] = field(default_factory=list)
    created: str | None = None
    valid_from: str | None = None
    valid_until: str | None = None
    links: list[str] = field(default_factory=list)
    path: Path | None = None
    raw: str = ""
    extra: dict[str, Any] = field(default_factory=dict)

    def is_valid_on(self, day: date) -> bool:
        start = _as_date(self.valid_from)
        end = _as_date(self.valid_until)
        return (start is None or start <= day) and (end is None or end >= day)

    def problems(self) -> list[str]:
        out = []
        if not NAME.match(self.name):
            out.append(f"name {self.name!r} is not a slug (lowercase letters, digits, . _ -)")
        if self.type not in TYPES:
            out.append(f"type {self.type!r} is not one of {', '.join(TYPES)}")
        if self.trust not in TRUSTS:
            out.append(f"trust {self.trust!r} is not one of {', '.join(TRUSTS)}")
        for key in ("created", "valid_from", "valid_until"):
            value = getattr(self, key)
            if value and _as_date(value) is None:
                out.append(f"{key} {value!r} is not a YYYY-MM-DD date")
        if not self.title.strip():
            out.append("no title")
        return out

    def to_markdown(self) -> str:
        fields: list[tuple[str, Any]] = [
            ("name", self.name),
            ("title", self.title),
            ("type", self.type),
            ("trust", self.trust),
            ("source", self.source),
            ("topics", self.topics),
            ("created", self.created),
            ("valid_from", self.valid_from),
            ("valid_until", self.valid_until),
            ("links", [link for link in self.links if link not in WIKILINK.findall(self.body)]),
            *sorted(self.extra.items()),
        ]
        lines = ["---"]
        for key, value in fields:
            if value in (None, "", []):
                continue
            if isinstance(value, list):
                value = "[" + ", ".join(_quote(str(v)) for v in value) + "]"
            else:
                value = _quote(str(value))
            lines.append(f"{key}: {value}")
        lines.append("---")
        return "\n".join(lines) + "\n\n" + self.body.strip() + "\n"


def parse_front_matter(text: str) -> tuple[dict[str, Any], str]:
    match = FRONT_MATTER.match(text)
    if not match:
        return {}, text
    data: dict[str, Any] = {}
    last: str | None = None
    for raw in match.group(1).splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        if indent == 0:
            key, _, value = line.partition(":")
            last = key.strip()
            data[last] = _scalar(value.strip()) if value.strip() else None
        elif last is not None and line.startswith("- "):
            if not isinstance(data.get(last), list):
                data[last] = []
            data[last].append(_scalar(line[2:].strip()))
        elif last is not None and ":" in line:
            if not isinstance(data.get(last), dict):
                data[last] = {}
            key, _, value = line.partition(":")
            data[last][key.strip()] = _scalar(value.strip())
    return data, text[match.end() :]


def parse_note(text: str, path: Path | None = None) -> Note:
    meta, body = parse_front_matter(text)
    metadata = meta.get("metadata") if isinstance(meta.get("metadata"), dict) else {}
    name = _string(meta.get("name")) or (path.stem if path else "note")
    memory_file = "description" in meta and "title" not in meta
    if path is not None and memory_file and not NAME.match(name.lower()):
        # Older Claude Code memory files name themselves with a sentence.
        name = path.stem
    heading = HEADING.search(body)
    title = (
        _string(meta.get("title"))
        or _string(meta.get("description"))
        or (heading.group(1) if heading else "")
        or name
    )
    links = _strings(meta.get("links"))
    for link in WIKILINK.findall(body):
        link = link.strip()
        if link and link not in links:
            links.append(link)
    known = {
        "name",
        "title",
        "description",
        "type",
        "trust",
        "source",
        "topics",
        "created",
        "valid_from",
        "valid_until",
        "links",
        "metadata",
    }
    return Note(
        name=name.lower(),
        title=title,
        body=body.strip(),
        type=_string(meta.get("type")) or _string(metadata.get("type")) or "fact",
        trust=_string(meta.get("trust")) or "agent",
        source=_string(meta.get("source")) or _string(metadata.get("originSessionId")),
        topics=[t.lower() for t in _strings(meta.get("topics"))],
        created=_string(meta.get("created")) or _day(_string(metadata.get("modified"))),
        valid_from=_string(meta.get("valid_from")),
        valid_until=_string(meta.get("valid_until")),
        links=links,
        path=path,
        raw=text,
        extra={k: v for k, v in meta.items() if k not in known},
    )


def load_note(path: Path) -> Note:
    return parse_note(path.read_text(encoding="utf-8", errors="replace"), path)


def iter_note_files(root: Path) -> list[Path]:
    if root.is_file():
        return [root]
    files = []
    for path in sorted(root.rglob("*.md")):
        relative = path.relative_to(root).parts
        if path.name in SKIPPED_FILES or any(p.startswith(".") for p in relative):
            continue
        files.append(path)
    return files


def load_notes(roots: list[Path]) -> list[Note]:
    return [load_note(path) for root in roots for path in iter_note_files(root)]


def add_links(path: Path, names: list[str]) -> bool:
    """Add ``names`` to the note's ``links`` and touch nothing else in the file: its other
    keys, their order, the body and the line endings stay as the author wrote them."""
    text = path.read_bytes().decode("utf-8")
    match = FRONT_MATTER.match(text)
    if not match or not names:
        return False
    newline = "\r\n" if "\r\n" in match.group(0) else "\n"
    lines = match.group(1).split(newline)
    for i, line in enumerate(lines):
        if not line.startswith("links:"):
            continue
        value = line[len("links:") :].strip()
        if value:
            current = _strings(_scalar(value))
            lines[i] = "links: [" + ", ".join(_quote(v) for v in [*current, *names]) + "]"
        else:
            end = i + 1
            while end < len(lines) and lines[end].lstrip().startswith("- "):
                end += 1
            lines[end:end] = [f"  - {_quote(name)}" for name in names]
        break
    else:
        lines.append("links: [" + ", ".join(_quote(name) for name in names) + "]")
    start, end = match.span(1)
    path.write_bytes((text[:start] + newline.join(lines) + text[end:]).encode("utf-8"))
    return True


def slugify(text: str, max_length: int = 60) -> str:
    import unicodedata

    ascii_text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_text.lower()).strip("-")
    return slug[:max_length].rstrip("-") or "note"


def _scalar(value: str) -> Any:
    if value.startswith("[") and value.endswith("]"):
        return [_unquote(v.strip()) for v in value[1:-1].split(",") if v.strip()]
    return _unquote(value)


def _unquote(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return re.sub(r"\\(.)", r"\1", value[1:-1])
    if len(value) >= 2 and value[0] == value[-1] == "'":
        return value[1:-1]
    return value


def _quote(value: str) -> str:
    value = " ".join(value.split())
    if value == "" or re.search(r"[:#\[\]{}\",']|^\s|\s$", value) or value.lower() in ("yes", "no"):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return value


def _string(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        return ", ".join(str(v) for v in value)
    return str(value).strip()


def _strings(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(v).strip() for v in value if str(v).strip()]
    return [v.strip() for v in str(value).split(",") if v.strip()]


def _day(value: str) -> str | None:
    return value[:10] if value and _as_date(value[:10]) else None


def _as_date(value: str | None) -> date | None:
    if not value:
        return None
    try:
        return date.fromisoformat(str(value)[:10])
    except ValueError:
        return None
