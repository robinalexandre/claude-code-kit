"""``kb site``: the whole base as one HTML page to read and explore, offline.

The page holds the notes themselves, decrypted: it is written next to the index, on this
computer only, never in the notes folder the sync shares. Nothing in it loads from the
network, and every note is escaped before it is shown: a note of trust ``third-party``
repeats what a web page or a mail said and may hold anything.
"""

from __future__ import annotations

import json
from datetime import date
from importlib import resources
from pathlib import Path
from typing import Any

from kb.graph import SIMILAR_MIN, Finding, Pair
from kb.notes import Note

PLACEHOLDER = "/*KB_DATA*/null"


def site_data(
    notes: list[Note],
    roots: list[Path],
    pairs: list[Pair],
    findings: list[Finding],
    today: date,
) -> dict[str, Any]:
    notes = sorted((n for n in notes if n.path is not None), key=lambda n: str(n.path))
    ids = {str(n.path.resolve()): i for i, n in enumerate(notes) if n.path is not None}
    first: dict[str, int] = {}
    for i, note in enumerate(notes):
        first.setdefault(note.name, i)
    folders = [_folder(n.path, roots) for n in notes if n.path is not None]
    known = {f for f in folders if f}
    nodes = []
    for note, folder in zip(notes, folders, strict=True):
        assert note.path is not None
        nodes.append(
            {
                "name": note.name,
                "title": note.title,
                "type": note.type,
                "trust": note.trust,
                "project": folder or _project_from_topics(note, known, roots),
                "topics": note.topics,
                "created": note.created,
                "valid_until": note.valid_until,
                "expired": bool(note.valid_until and note.valid_until[:10] < today.isoformat()),
                "source": note.source,
                "path": _relative(note.path, roots),
                "body": note.body,
            }
        )
    links: set[tuple[int, int]] = set()
    for i, note in enumerate(notes):
        for link in note.links:
            j = first.get(link.lower())
            if j is not None and j != i:
                links.add((i, j))
    undirected = {frozenset(pair) for pair in links}
    similar = []
    for pair in pairs:
        a, b = ids.get(pair.a), ids.get(pair.b)
        if a is None or b is None or pair.score < SIMILAR_MIN:
            continue
        if frozenset((a, b)) in undirected:
            continue
        similar.append([a, b, pair.score])
    return {
        "generated": today.isoformat(),
        "nodes": nodes,
        "links": sorted([a, b] for a, b in links),
        "similar": similar,
        "findings": [
            {
                "kind": f.kind,
                "name": f.name,
                "detail": f.detail,
                "id": ids.get(str(Path(f.path).resolve()), -1),
            }
            for f in findings
        ],
    }


def render(data: dict[str, Any]) -> str:
    template = resources.files("kb").joinpath("site.html").read_text(encoding="utf-8")
    # < keeps a note's "</script>" from closing the page's script.
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    return template.replace(PLACEHOLDER, payload)


def _folder(path: Path, roots: list[Path]) -> str | None:
    """The folder a note sits in under its root (a repository's memory, say); None for a
    note at the root itself."""
    for root in roots:
        try:
            relative = path.resolve().relative_to(root.resolve())
        except ValueError:
            continue
        return relative.parent.name.lower() if len(relative.parts) > 1 else None
    return None


def _project_from_topics(note: Note, known: set[str], roots: list[Path]) -> str:
    for topic in note.topics:
        if topic in known:
            return topic
    if note.topics:
        return note.topics[0]
    for root in roots:
        try:
            note.path.resolve().relative_to(root.resolve())  # type: ignore[union-attr]
            return root.name.lower()
        except ValueError:
            continue
    return "notes"


def _relative(path: Path, roots: list[Path]) -> str:
    for root in roots:
        try:
            return f"{root.name}/{path.resolve().relative_to(root.resolve()).as_posix()}"
        except ValueError:
            continue
    return path.name
