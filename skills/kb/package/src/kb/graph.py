"""The shape of the base: which notes are alike, the links worth adding, and its health.

A note's vector is the mean of its chunks' vectors, already in the index, so nothing here
loads the model. Similar notes are linked in the notes folder kb writes to (the first one);
Claude Code's memory folders are read only, and their likeness shows in the site instead.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any

from kb.index import Index, pack, unpack
from kb.notes import Note, add_links

LINK_MIN = 0.6
SIMILAR_MIN = 0.55
DUPLICATE_MIN = 0.85
LINKS_PER_RUN = 3
STALE_DAYS = 120
DATED_HEADING = re.compile(r"^##\s+(\d{4}-\d{2}-\d{2})\s*$", re.M)
STALE_TYPES = ("project", "decision")


@dataclass
class Pair:
    a: str
    b: str
    score: float


@dataclass
class Finding:
    kind: str
    path: str
    name: str
    detail: str

    def as_dict(self) -> dict[str, Any]:
        return self.__dict__.copy()


def note_vectors(index: Index) -> dict[str, list[float]]:
    """Path → the normalised mean of its chunks' vectors."""
    sums: dict[str, list[float]] = {}
    rows = index.conn.execute(
        "SELECT n.path, c.embedding FROM chunks c JOIN notes n ON n.id = c.note_id"
        " WHERE c.embedding IS NOT NULL"
    )
    for row in rows:
        vector = unpack(row["embedding"])
        current = sums.get(row["path"])
        if current is None:
            sums[row["path"]] = list(vector)
        elif len(current) == len(vector):
            sums[row["path"]] = [x + y for x, y in zip(current, vector, strict=True)]
    out = {}
    for path, total in sums.items():
        norm = math.sqrt(sum(x * x for x in total))
        if norm:
            out[path] = [x / norm for x in total]
    return out


def similar_pairs(index: Index, min_score: float = SIMILAR_MIN, per_note: int = 3) -> list[Pair]:
    """Each note's ``per_note`` nearest notes scoring ``min_score`` or more (cosine), every
    pair once, best first."""
    vectors = note_vectors(index)
    paths = list(vectors)
    neighbours = (
        _nearest_vec(index, vectors, per_note)
        if index.vec and len(paths) > per_note
        else _nearest_brute(vectors, per_note)
    )
    best: dict[tuple[str, str], float] = {}
    for path, near in neighbours.items():
        for other, score in near:
            if score < min_score or other == path:
                continue
            key = (min(path, other), max(path, other))
            best[key] = max(best.get(key, 0.0), score)
    pairs = [Pair(a, b, round(score, 3)) for (a, b), score in best.items()]
    pairs.sort(key=lambda p: (-p.score, p.a, p.b))
    return pairs


def reads_like(
    index: Index, path: str, limit: int = 5, min_score: float = SIMILAR_MIN
) -> list[tuple[str, float]]:
    """The notes nearest to the one at ``path``, as (path, cosine), best first."""
    vectors = note_vectors(index)
    root = vectors.get(path)
    if root is None:
        return []
    scored = [
        (other, sum(x * y for x, y in zip(root, vector, strict=True)))
        for other, vector in vectors.items()
        if other != path and len(vector) == len(root)
    ]
    scored = [(p, round(s, 3)) for p, s in scored if s >= min_score]
    return sorted(scored, key=lambda t: -t[1])[:limit]


def related(index: Index, name: str, depth: int = 2) -> tuple[list[dict[str, Any]], list[tuple]]:
    """``Index.related``, then the notes that read like the root and were not reached yet,
    marked ``via: reads like <score>``: a note with no link still has neighbours."""
    nodes, edges = index.related(name, depth)
    root = index.get(name)
    if root is None:
        return nodes, edges
    reached = {n["name"] for n in nodes} | {root["name"]}
    for path, score in reads_like(index, root["path"]):
        row = index.conn.execute(
            "SELECT name, title, type, path FROM notes WHERE path = ?", (path,)
        ).fetchone()
        if row is None or row["name"] in reached:
            continue
        reached.add(row["name"])
        nodes.append({**dict(row), "depth": 1, "via": f"reads like {score:.2f}"})
    return nodes, edges


def _nearest_brute(
    vectors: dict[str, list[float]], per_note: int
) -> dict[str, list[tuple[str, float]]]:
    paths = list(vectors)
    scored: dict[str, list[tuple[str, float]]] = {p: [] for p in paths}
    for i, a in enumerate(paths):
        for b in paths[i + 1 :]:
            if len(vectors[a]) != len(vectors[b]):
                continue
            score = sum(x * y for x, y in zip(vectors[a], vectors[b], strict=True))
            scored[a].append((b, score))
            scored[b].append((a, score))
    return {p: sorted(s, key=lambda t: -t[1])[:per_note] for p, s in scored.items()}


def _nearest_vec(
    index: Index, vectors: dict[str, list[float]], per_note: int
) -> dict[str, list[tuple[str, float]]]:
    """sqlite-vec's nearest neighbours over a temporary table of note vectors: a large base
    stays fast. On unit vectors, cosine = 1 - distance² / 2."""
    paths = list(vectors)
    dim = len(next(iter(vectors.values())))
    conn = index.conn
    conn.execute("DROP TABLE IF EXISTS temp.note_vec")
    conn.execute(f"CREATE VIRTUAL TABLE temp.note_vec USING vec0(embedding float[{dim}])")
    for rowid, path in enumerate(paths, 1):
        if len(vectors[path]) == dim:
            conn.execute(
                "INSERT INTO temp.note_vec(rowid, embedding) VALUES (?, ?)",
                (rowid, pack(vectors[path])),
            )
    out: dict[str, list[tuple[str, float]]] = {}
    for path in paths:
        if len(vectors[path]) != dim:
            continue
        rows = conn.execute(
            "SELECT rowid, distance FROM temp.note_vec WHERE embedding MATCH ? AND k = ?",
            (pack(vectors[path]), per_note + 1),
        ).fetchall()
        out[path] = [
            (paths[r["rowid"] - 1], 1 - r["distance"] ** 2 / 2)
            for r in rows
            if paths[r["rowid"] - 1] != path
        ][:per_note]
    conn.execute("DROP TABLE temp.note_vec")
    return out


def links_to_add(
    notes: list[Note],
    pairs: list[Pair],
    writable: Path,
    min_score: float = LINK_MIN,
    per_note: int = LINKS_PER_RUN,
) -> dict[Path, list[tuple[str, float]]]:
    """For each similar pair not linked yet, a link from the note kb may write (in the
    ``writable`` folder) to the other one; never a name the note lists under ``unlink``,
    never two notes of the same name, at most ``per_note`` new links per note."""
    by_path = {str(n.path.resolve()): n for n in notes if n.path is not None}
    root = writable.resolve()
    linked = {
        frozenset((note.name, link.lower())) for note in by_path.values() for link in note.links
    }
    out: dict[Path, list[tuple[str, float]]] = {}
    for pair in pairs:
        if pair.score < min_score:
            continue
        a, b = by_path.get(pair.a), by_path.get(pair.b)
        if a is None or b is None or a.name == b.name:
            continue
        if frozenset((a.name, b.name)) in linked:
            continue
        for src, dst in ((a, b), (b, a)):
            assert src.path is not None
            if not _under(src.path, root) or dst.name in _unlinked(src):
                continue
            added = out.setdefault(src.path, [])
            if len(added) >= per_note:
                continue
            added.append((dst.name, pair.score))
            linked.add(frozenset((a.name, b.name)))
            break
    return {path: names for path, names in out.items() if names}


def apply_links(plan: dict[Path, list[tuple[str, float]]]) -> int:
    return sum(len(names) for path, names in plan.items() if add_links(path, [n for n, _ in names]))


def links_report(plan: dict[Path, list[tuple[str, float]]], notes: list[Note], day: date) -> str:
    names = {str(n.path): n.name for n in notes if n.path is not None}
    lines = [f"# Links of {day.isoformat()}", ""]
    total = sum(len(v) for v in plan.values())
    lines.append(f"{total} link(s) added between notes that read alike.")
    lines.append("To drop one, move its name from `links` to `unlink` in the note.")
    lines.append("")
    for path, added in sorted(plan.items(), key=lambda kv: str(kv[0])):
        src = names.get(str(path), path.stem)
        for dst, score in added:
            lines.append(f"- {src} → {dst} ({score:.2f})")
    return "\n".join(lines) + "\n"


def lint(
    notes: list[Note],
    pairs: list[Pair],
    today: date,
    stale_days: int = STALE_DAYS,
    duplicate_min: float = DUPLICATE_MIN,
) -> list[Finding]:
    """What a person would tidy: malformed notes, links to nothing, notes linked to nothing,
    projects and decisions that have not moved for months, notes that say the same thing.
    A note with no link is an orphan only when no pair has it either."""
    findings: list[Finding] = []
    names = {n.name for n in notes}
    linked_to = {link.lower() for n in notes for link in n.links}
    alike = {p.a for p in pairs} | {p.b for p in pairs}

    def path_key(note: Note) -> str:
        return str(note.path.resolve()) if note.path is not None else ""

    seen: dict[str, Path] = {}
    for note in notes:
        path = str(note.path)
        for problem in note.problems():
            findings.append(Finding("malformed", path, note.name, problem))
        for link in note.links:
            if link.lower() not in names:
                findings.append(Finding("dangling", path, note.name, f"links to {link!r}"))
        if note.name in seen and note.path is not None:
            findings.append(Finding("same-name", path, note.name, f"also in {seen[note.name]}"))
        elif note.path is not None:
            seen[note.name] = note.path
        if not note.links and note.name not in linked_to and path_key(note) not in alike:
            findings.append(
                Finding("orphan", path, note.name, "no link in or out, and nothing reads like it")
            )
        last = last_dated(note)
        expired = note.valid_until and note.valid_until[:10] < today.isoformat()
        if (
            note.type in STALE_TYPES
            and not expired
            and last is not None
            and last < today - timedelta(days=stale_days)
        ):
            findings.append(
                Finding(
                    "stale",
                    path,
                    note.name,
                    f"{note.type} last dated {last.isoformat()}: still true? "
                    "Add a valid_until if not",
                )
            )
    by_path = {str(n.path.resolve()): n for n in notes if n.path is not None}
    for pair in pairs:
        if pair.score < duplicate_min:
            continue
        a, b = by_path.get(pair.a), by_path.get(pair.b)
        if a is None or b is None or a.name == b.name:
            continue
        findings.append(
            Finding(
                "near-duplicate", str(a.path), a.name, f"reads like {b.name} ({pair.score:.2f})"
            )
        )
    order = {k: i for i, k in enumerate(KINDS)}
    findings.sort(key=lambda f: (order.get(f.kind, 99), f.name, f.path))
    return findings


KINDS = ("malformed", "dangling", "same-name", "near-duplicate", "stale", "orphan")


def last_dated(note: Note) -> date | None:
    days = [note.created, note.valid_from, *DATED_HEADING.findall(note.body)]
    parsed = []
    for value in days:
        try:
            parsed.append(date.fromisoformat(str(value)[:10]))
        except (TypeError, ValueError):
            continue
    return max(parsed) if parsed else None


def _unlinked(note: Note) -> set[str]:
    value = note.extra.get("unlink")
    if isinstance(value, list):
        return {str(v).strip().lower() for v in value}
    return {v.strip().lower() for v in str(value or "").split(",") if v.strip()}


def _under(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root)
        return True
    except ValueError:
        return False
