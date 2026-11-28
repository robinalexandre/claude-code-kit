"""The shape of the base: which notes are alike, the links worth adding, and its health.

A note's vector is the mean of its chunks' vectors, already in the index, so nothing here
loads the model. Similar notes are linked in the notes folder kb writes to (the first one);
Claude Code's memory folders are read only, and their likeness shows in the site instead.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from typing import Any

from kb.index import NODE_COLUMNS, Index, node_fields, pack, row_extra, unpack
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


def similar_pairs(
    index: Index,
    min_score: float = SIMILAR_MIN,
    per_note: int = 3,
    vectors: dict[str, list[float]] | None = None,
) -> list[Pair]:
    """Each note's ``per_note`` nearest notes scoring ``min_score`` or more (cosine), every
    pair once, best first."""
    vectors = note_vectors(index) if vectors is None else vectors
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
            f"SELECT {NODE_COLUMNS} FROM notes WHERE path = ?",  # noqa: S608 - fixed columns
            (path,),
        ).fetchone()
        if row is None or row["name"] in reached:
            continue
        reached.add(row["name"])
        nodes.append({**node_fields(row), "depth": 1, "via": f"reads like {score:.2f}"})
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
    writable: Path | None = None,
) -> list[Finding]:
    """What a person would tidy: malformed notes, links to nothing, notes linked to nothing,
    projects and decisions that have not moved for months, notes that say the same thing.
    A note with no link is an orphan only when no pair has it either. Outside ``writable``
    (Claude Code's memory, where a link may name a note not written yet and each project
    has its own names) only staleness and near-duplicates count."""
    findings: list[Finding] = []
    names = {n.name for n in notes}
    linked_to = {link.lower() for n in notes for link in n.links}
    alike = {p.a for p in pairs} | {p.b for p in pairs}
    root = writable.resolve() if writable is not None else None

    def path_key(note: Note) -> str:
        return str(note.path.resolve()) if note.path is not None else ""

    def owned(note: Note) -> bool:
        return root is None or (note.path is not None and note.path.resolve().is_relative_to(root))

    seen: dict[str, Note] = {}
    for note in notes:
        path = str(note.path)
        mine = owned(note)
        if note.name in seen and note.path is not None:
            first = seen[note.name]
            if mine or owned(first):
                findings.append(Finding("same-name", path, note.name, f"also in {first.path}"))
        elif note.path is not None:
            seen[note.name] = note
        if mine:
            for problem in note.problems():
                findings.append(Finding("malformed", path, note.name, problem))
            for link in note.links:
                if link.lower() not in names:
                    findings.append(Finding("dangling", path, note.name, f"links to {link!r}"))
        if mine and not note.links and note.name not in linked_to and path_key(note) not in alike:
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


# --- The map: every note with its place in 3D, its links, its look-alikes, its group ----

GRAPH_FILE = "graph.json"
LAYOUT_FILE = "layout.json"
NOTE_FIELDS = (
    "id, path, name, title, type, trust, source, topics, created, valid_from, valid_until,"
    " root, rel_path, rank, extra, hash, length(body) AS chars"
)


class GraphUnavailable(RuntimeError):
    """The map needs numpy (``pip install 'kb[graph]'``)."""


@dataclass
class MapData:
    """What the map is computed from, read from the index in one go."""

    rows: list[dict[str, Any]]
    links: list[tuple[int, str]]
    vectors: dict[str, list[float]]
    pairs: list[Pair]
    embedder: str
    digest: str


def note_key(row: dict[str, Any], shared: frozenset[str] = frozenset()) -> str:
    """A note's identity on the map: its root and its path there, never an absolute path.
    A root whose folder name another root also has (``shared``) adds its rank."""
    if row["root"]:
        root = f"{row['root']}#{row['rank']}" if row["root"] in shared else row["root"]
        return f"{root}/{row['rel_path']}"
    return "path:" + hashlib.sha256(row["path"].encode()).hexdigest()[:16]


def shared_roots(rows: list[dict[str, Any]]) -> frozenset[str]:
    """The root folder names that more than one root has."""
    ranks: dict[str, set[Any]] = {}
    for row in rows:
        if row["root"]:
            ranks.setdefault(row["root"], set()).add(row["rank"])
    return frozenset(name for name, seen in ranks.items() if len(seen) > 1)


def map_digest(index: Index) -> str:
    """Changes when a note is added, removed, edited, moved or embedded, or the layout's
    version or the embedder changes: the only times the map is computed again."""
    from kb.layout import VERSION

    digest = hashlib.sha256(f"layout {VERSION}\n".encode())
    stored = index.conn.execute("SELECT value FROM meta WHERE key = 'embedder'").fetchone()
    digest.update(f"{stored['value'] if stored else ''}\n".encode())
    rows = index.conn.execute(
        "SELECT n.root, n.rel_path, n.rank, n.path, n.hash, n.extra,"
        " (SELECT COUNT(*) FROM chunks c WHERE c.note_id = n.id AND c.embedding IS NOT NULL)"
        " AS embedded FROM notes n ORDER BY n.rank, n.rel_path, n.path"
    )
    for row in rows:
        digest.update(json.dumps(list(row), default=str).encode() + b"\n")
    return digest.hexdigest()


def collect(index: Index) -> MapData:
    """Everything the map needs from the index; quick, so it can run under the server's
    lock while the layout itself runs outside it."""
    rows = [
        dict(r)
        for r in index.conn.execute(
            f"SELECT {NOTE_FIELDS} FROM notes ORDER BY rank, rel_path, path"  # noqa: S608 - fixed
        ).fetchall()
    ]
    links = [
        (r["from_id"], r["to_name"])
        for r in index.conn.execute("SELECT from_id, to_name FROM links ORDER BY from_id, to_name")
    ]
    vectors = note_vectors(index)
    pairs = similar_pairs(index, vectors=vectors)
    stored = index.conn.execute("SELECT value FROM meta WHERE key = 'embedder'").fetchone()
    has_vectors = bool(vectors)
    return MapData(
        rows,
        links,
        vectors,
        pairs,
        stored["value"] if stored and has_vectors else "",
        map_digest(index),
    )


def compose(data: MapData, previous: Any, now: datetime) -> tuple[dict[str, Any], dict[str, Any]]:
    """The graph of API §14.2 and the layout state to keep for the next run."""
    try:
        import numpy as np

        from kb.layout import VERSION, Item, place
    except ImportError as exc:  # pragma: no cover - numpy comes with the embed extra
        raise GraphUnavailable("the map needs numpy: pip install 'kb[graph]'") from exc

    rows = data.rows
    by_id = {row["id"]: i for i, row in enumerate(rows)}
    by_path = {row["path"]: i for i, row in enumerate(rows)}
    first: dict[str, int] = {}
    for i, row in enumerate(rows):
        first.setdefault(row["name"], i)
    links: set[tuple[int, int]] = set()
    dangling = 0
    for from_id, to_name in data.links:
        a, b = by_id.get(from_id), first.get(to_name)
        if a is None:
            continue
        if b is None:
            dangling += 1
        elif a != b:
            links.add((a, b))
    linked = {frozenset(pair) for pair in links}
    similar = []
    for pair in data.pairs:
        a, b = by_path.get(pair.a), by_path.get(pair.b)
        if a is None or b is None or a == b or frozenset((a, b)) in linked:
            continue
        similar.append([min(a, b), max(a, b), pair.score])
    similar.sort()
    degree = [0] * len(rows)
    for a, b in links:
        degree[a] += 1
        degree[b] += 1
    alike = [0] * len(rows)
    for a, b, _ in similar:
        alike[a] += 1
        alike[b] += 1
    raw_weight = [math.sqrt(d + 0.5 * s) for d, s in zip(degree, alike, strict=True)]
    top = max(raw_weight, default=0.0) or 1.0
    projects = [_project(row) for row in rows]
    topics = [json.loads(row["topics"]) for row in rows]
    shared = shared_roots(rows)
    items = [
        Item(
            key=note_key(row, shared),
            vector=np.array(data.vectors[row["path"]]) if row["path"] in data.vectors else None,
            topics=topics[i],
            project=projects[i],
            degree=degree[i],
        )
        for i, row in enumerate(rows)
    ]
    placement = place(items, sorted(links), data.embedder, previous)
    stamp = now.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    full_at = stamp if placement.full else getattr(previous, "full_at", None) or stamp
    today = now.date().isoformat()
    nodes = []
    for i, row in enumerate(rows):
        valid_until = row["valid_until"]
        nodes.append(
            {
                "name": row["name"],
                "title": row["title"],
                "type": row["type"],
                "trust": row["trust"],
                "source": row["source"],
                "topics": topics[i],
                "created": row["created"],
                "valid_from": row["valid_from"],
                "valid_until": valid_until,
                "expired": bool(valid_until and valid_until[:10] < today),
                "root": row["root"],
                "rel_path": row["rel_path"],
                "project": projects[i],
                "extra": row_extra(row),
                "hash": row["hash"],
                "chars": row["chars"],
                "degree": degree[i],
                "weight": round(raw_weight[i] / top, 4),
                "cluster": placement.groups[i],
                "pos": placement.positions[i],
            }
        )
    content = {
        "nodes": nodes,
        "links": [list(pair) for pair in sorted(links)],
        "similar": similar,
        "clusters": placement.group_info,
        "dangling": dangling,
    }
    layout_info = {"method": placement.method, "version": VERSION, "embedder": data.embedder}
    blob = json.dumps({**content, "layout": layout_info}, ensure_ascii=False, sort_keys=True)
    graph = {
        "rev": hashlib.sha256(blob.encode()).hexdigest()[:12],
        "layout": {
            "method": placement.method,
            "version": VERSION,
            "status": "ready",
            "computed_at": stamp,
            "full_at": full_at,
            "embedder": data.embedder,
        },
        **content,
    }
    state = {
        "version": VERSION,
        "method": placement.method,
        "embedder": data.embedder,
        "scale": placement.scale,
        "full_at": full_at,
        "full_keys": sorted(placement.full_keys),
        "positions": {item.key: placement.positions[i] for i, item in enumerate(items)},
        "groups": {gid: sorted(keys) for gid, keys in sorted(placement.group_members.items())},
        "input": data.digest,
    }
    return graph, state


def _project(row: dict[str, Any]) -> str:
    folder = Path(row["rel_path"]).parent.as_posix() if row["rel_path"] else "."
    return folder.rsplit("/", 1)[-1].lower() if folder != "." else row["root"] or "notes"


def read_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_json(path: Path, data: Any) -> None:
    """Written whole or not at all: a reader never sees half a file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.tmp")
    temp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    try:
        temp.chmod(0o600)
    except OSError:
        pass
    os.replace(temp, path)


def stored_map(data_dir: Path) -> tuple[dict[str, Any] | None, dict[str, Any] | None]:
    graph, state = read_json(data_dir / GRAPH_FILE), read_json(data_dir / LAYOUT_FILE)
    if not isinstance(graph, dict) or not isinstance(state, dict):
        return None, None
    return graph, state


def refresh_map(
    data: MapData,
    data_dir: Path,
    now: datetime | None = None,
    stored: tuple[dict[str, Any] | None, dict[str, Any] | None] | None = None,
) -> tuple[dict[str, Any], dict[str, Any], bool]:
    """The map for ``data``: the stored one when nothing it depends on changed, else
    computed again (incrementally from the stored layout when it can) and written to
    ``graph.json`` and ``layout.json`` in ``data_dir``. Returns the graph, the layout
    state and whether they changed."""
    from kb.layout import Previous

    graph, state = stored if stored is not None else stored_map(data_dir)
    if graph is not None and state is not None and state.get("input") == data.digest:
        return graph, state, False
    previous = Previous.from_json(state) if state is not None else None
    graph, state = compose(data, previous, now or datetime.now(UTC))
    write_json(data_dir / LAYOUT_FILE, state)
    write_json(data_dir / GRAPH_FILE, graph)
    return graph, state, True


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
