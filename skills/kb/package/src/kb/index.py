"""The SQLite index over the notes: full text (FTS5), vectors (sqlite-vec) and links.

The index is a cache: deleting it loses nothing, ``update`` rebuilds it from the notes.
Vectors are kept as blobs in ``chunks`` too, so a build of SQLite that cannot load the
sqlite-vec extension still searches, by brute force, which is fine for a personal base.
"""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import struct
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path
from typing import Any

from kb.embed import Embedder
from kb.notes import Note

CHUNK_CHARS = 800
CANDIDATES = 50
AUTO_ENOUGH = 3
STEM_CHARS = 5
RRF_K = 60
TOKEN = re.compile(r"\w+", re.UNICODE)

SCHEMA = """
CREATE TABLE IF NOT EXISTS notes (
    id INTEGER PRIMARY KEY,
    path TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    title TEXT NOT NULL,
    type TEXT NOT NULL,
    trust TEXT NOT NULL,
    source TEXT NOT NULL DEFAULT '',
    topics TEXT NOT NULL DEFAULT '[]',
    created TEXT,
    valid_from TEXT,
    valid_until TEXT,
    body TEXT NOT NULL,
    hash TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS notes_name ON notes(name);
CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
    title, body, topics, name, tokenize='unicode61 remove_diacritics 2'
);
CREATE TABLE IF NOT EXISTS links (
    from_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    to_name TEXT NOT NULL,
    PRIMARY KEY (from_id, to_name)
);
CREATE INDEX IF NOT EXISTS links_to ON links(to_name);
CREATE TABLE IF NOT EXISTS chunks (
    id INTEGER PRIMARY KEY,
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    ord INTEGER NOT NULL,
    text TEXT NOT NULL,
    embedding BLOB
);
CREATE INDEX IF NOT EXISTS chunks_note ON chunks(note_id);
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""
VEC_SCHEMA = (
    "CREATE VIRTUAL TABLE IF NOT EXISTS chunks_vec USING vec0("
    "chunk_id INTEGER PRIMARY KEY, embedding float[DIM])"
)


@dataclass
class Hit:
    path: str
    name: str
    title: str
    type: str
    trust: str
    score: float
    snippet: str
    topics: list[str] = field(default_factory=list)
    valid_until: str | None = None
    source: str = ""

    def as_dict(self) -> dict[str, Any]:
        return self.__dict__.copy()


@dataclass
class UpdateStats:
    added: int = 0
    changed: int = 0
    removed: int = 0
    unchanged: int = 0
    chunks_embedded: int = 0


class Index:
    def __init__(
        self, db_path: Path | str, embedder: Embedder | None = None, *, shared: bool = False
    ) -> None:
        """``shared``: the server uses the index from several threads, one at a time."""
        if isinstance(db_path, Path):
            db_path.parent.mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(str(db_path), check_same_thread=not shared)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        self.embedder = embedder
        self.vec = self._load_vec()
        self.conn.executescript(SCHEMA)
        self._vectors_ready = False

    def close(self) -> None:
        self.conn.close()

    def _load_vec(self) -> bool:
        try:
            import sqlite_vec

            self.conn.enable_load_extension(True)
            sqlite_vec.load(self.conn)
            self.conn.enable_load_extension(False)
            return True
        except (ImportError, AttributeError, sqlite3.Error):
            return False

    def _prepare_vectors(self) -> None:
        """Vectors from another model are useless: a model change re-embeds everything.
        Called only when vectors are about to be used, so the model loads only then."""
        if self.embedder is None or self._vectors_ready:
            return
        self._vectors_ready = True
        stored = self.conn.execute("SELECT value FROM meta WHERE key = 'embedder'").fetchone()
        current = f"{self.embedder.name}:{self.embedder.dim}"
        if stored and stored["value"] != current:
            self.conn.execute("UPDATE chunks SET embedding = NULL")
            self.conn.execute("DROP TABLE IF EXISTS chunks_vec")
        self.conn.execute(
            "INSERT OR REPLACE INTO meta(key, value) VALUES ('embedder', ?)", (current,)
        )
        if self.vec:
            self.conn.execute(VEC_SCHEMA.replace("DIM", str(self.embedder.dim)))
        self.conn.commit()

    def update(self, notes: list[Note], roots: list[Path] | None = None) -> UpdateStats:
        stats = UpdateStats()
        seen: set[str] = set()
        to_embed: list[tuple[int, str]] = []
        for note in notes:
            if note.path is None:
                continue
            path = str(note.path.resolve())
            seen.add(path)
            digest = hashlib.sha256(note.raw.encode("utf-8", "replace")).hexdigest()
            row = self.conn.execute("SELECT id, hash FROM notes WHERE path = ?", (path,)).fetchone()
            if row and row["hash"] == digest:
                stats.unchanged += 1
                continue
            if row:
                stats.changed += 1
                self._remove(row["id"])
            else:
                stats.added += 1
            note_id = self._insert(note, path, digest)
            for ord_, text in enumerate(chunk(note.title, note.body)):
                cur = self.conn.execute(
                    "INSERT INTO chunks(note_id, ord, text) VALUES (?, ?, ?)", (note_id, ord_, text)
                )
                to_embed.append((cur.lastrowid, text))
        for row in self.conn.execute("SELECT id, path FROM notes").fetchall():
            if row["path"] in seen:
                continue
            if roots and not any(_under(row["path"], root) for root in roots):
                continue
            self._remove(row["id"])
            stats.removed += 1
        if self.embedder is not None:
            self._prepare_vectors()
            missing = self.conn.execute(
                "SELECT id, text FROM chunks WHERE embedding IS NULL"
            ).fetchall()
            pending = {row["id"]: row["text"] for row in missing}
            pending.update(dict(to_embed))
            stats.chunks_embedded = self._embed(list(pending.items()))
        self.conn.commit()
        return stats

    def _insert(self, note: Note, path: str, digest: str) -> int:
        cur = self.conn.execute(
            "INSERT INTO notes(path, name, title, type, trust, source, topics, created,"
            " valid_from, valid_until, body, hash) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (
                path,
                note.name,
                note.title,
                note.type,
                note.trust,
                note.source,
                json.dumps(note.topics, ensure_ascii=False),
                note.created,
                note.valid_from,
                note.valid_until,
                note.body,
                digest,
            ),
        )
        note_id = cur.lastrowid
        assert note_id is not None
        self.conn.execute(
            "INSERT INTO notes_fts(rowid, title, body, topics, name) VALUES (?,?,?,?,?)",
            (note_id, note.title, note.body, " ".join(note.topics), note.name.replace("-", " ")),
        )
        self.conn.executemany(
            "INSERT OR IGNORE INTO links(from_id, to_name) VALUES (?, ?)",
            [(note_id, link.lower()) for link in note.links],
        )
        return note_id

    def _remove(self, note_id: int) -> None:
        rows = self.conn.execute("SELECT id FROM chunks WHERE note_id = ?", (note_id,))
        chunk_ids = [r["id"] for r in rows]
        if self.vec and chunk_ids:
            self.conn.executemany(
                "DELETE FROM chunks_vec WHERE chunk_id = ?", [(c,) for c in chunk_ids]
            )
        self.conn.execute("DELETE FROM notes_fts WHERE rowid = ?", (note_id,))
        self.conn.execute("DELETE FROM notes WHERE id = ?", (note_id,))

    def _embed(self, items: list[tuple[int, str]]) -> int:
        assert self.embedder is not None
        for start in range(0, len(items), 64):
            batch = items[start : start + 64]
            vectors = self.embedder.embed([text for _, text in batch])
            for (chunk_id, _), vector in zip(batch, vectors, strict=True):
                blob = pack(vector)
                self.conn.execute("UPDATE chunks SET embedding = ? WHERE id = ?", (blob, chunk_id))
                if self.vec:
                    self.conn.execute(
                        "INSERT OR REPLACE INTO chunks_vec(chunk_id, embedding) VALUES (?, ?)",
                        (chunk_id, blob),
                    )
        return len(items)

    def search(
        self,
        query: str,
        limit: int = 10,
        types: list[str] | None = None,
        topic: str | None = None,
        valid_on: date | None = None,
        trust: list[str] | None = None,
        mode: str = "auto",
    ) -> list[Hit]:
        """Text and vector candidates merged by reciprocal rank fusion, then filtered.

        ``text`` never loads the model. ``auto`` is text-only when every word of the query
        matches a few notes (a precise query), hybrid otherwise. ``hybrid`` always is.
        """
        filters = (types, topic, valid_on, trust)
        if mode in ("auto", "text"):
            exact = self._rank(self._text_candidates(query, require_all=True), [], filters, limit)
            if mode == "text" or len(exact) >= min(limit, AUTO_ENOUGH):
                return exact
        return self._rank(
            self._text_candidates(query), self._vector_candidates(query), filters, limit
        )

    def _rank(
        self,
        text: list[tuple[int, str]],
        vectors: list[tuple[int, str]],
        filters: tuple,
        limit: int,
    ) -> list[Hit]:
        ranked: dict[int, float] = {}
        snippets: dict[int, str] = {}
        for candidates in (text, vectors):
            for rank, (note_id, snippet) in enumerate(candidates):
                ranked[note_id] = ranked.get(note_id, 0.0) + 1.0 / (RRF_K + rank)
                snippets.setdefault(note_id, snippet)
        hits = []
        for note_id, score in sorted(ranked.items(), key=lambda kv: -kv[1]):
            row = self.conn.execute("SELECT * FROM notes WHERE id = ?", (note_id,)).fetchone()
            if row is None or not self._passes(row, *filters):
                continue
            hits.append(_hit(row, score, snippets.get(note_id, "")))
            if len(hits) >= limit:
                break
        return hits

    def _text_candidates(self, query: str, require_all: bool = False) -> list[tuple[int, str]]:
        """Full-text candidates. ``require_all`` is the precise mode: every content word
        must appear when there are few, most of them when the query is a whole sentence,
        so a prompt pasted as a query still finds the note it is about."""
        tokens = [t for t in TOKEN.findall(query) if len(t) > 1]
        needed = 0
        if require_all:
            tokens = list(dict.fromkeys(content_words(query)))
            needed = len(tokens) if len(tokens) <= 3 else -(-len(tokens) * 7 // 10)
        if not tokens:
            return []
        joiner = " AND " if require_all and needed == len(tokens) else " OR "
        match = joiner.join('"' + t.replace('"', "") + '"' for t in tokens)
        rows = self.conn.execute(
            "SELECT rowid, snippet(notes_fts, 1, '[', ']', '…', 32) AS snip, title, body, topics"
            " FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts, 4.0, 1.0, 2.0, 3.0)"
            " LIMIT ?",
            (match, CANDIDATES if joiner == " OR " and not require_all else CANDIDATES * 4),
        ).fetchall()
        if require_all and needed < len(tokens):
            kept = []
            stems = [fold(t)[:STEM_CHARS] for t in tokens]
            for r in rows:
                words = {w[:STEM_CHARS] for w in TOKEN.findall(fold(f"{r['title']} {r['body']}"))}
                if sum(1 for s in stems if s in words) >= needed:
                    kept.append(r)
            rows = kept[:CANDIDATES]
        return [(r["rowid"], r["snip"]) for r in rows]

    def _vector_candidates(self, query: str) -> list[tuple[int, str]]:
        if self.embedder is None:
            return []
        self._prepare_vectors()
        vector = self.embedder.embed([query])[0]
        if self.vec:
            rows = self.conn.execute(
                "SELECT c.note_id, c.text FROM chunks_vec v JOIN chunks c ON c.id = v.chunk_id"
                " WHERE v.embedding MATCH ? AND k = ? ORDER BY v.distance",
                (pack(vector), CANDIDATES),
            ).fetchall()
            scored = [(r["note_id"], r["text"]) for r in rows]
        else:
            scored = self._brute_force(vector)
        out: list[tuple[int, str]] = []
        seen: set[int] = set()
        for note_id, text in scored:
            if note_id not in seen:
                seen.add(note_id)
                out.append((note_id, text[:160]))
        return out

    def _brute_force(self, vector: list[float]) -> list[tuple[int, str]]:
        rows = self.conn.execute(
            "SELECT note_id, text, embedding FROM chunks WHERE embedding IS NOT NULL"
        ).fetchall()
        scored = []
        for row in rows:
            other = unpack(row["embedding"])
            if len(other) != len(vector):
                continue
            scored.append((sum(a * b for a, b in zip(vector, other, strict=True)), row))
        scored.sort(key=lambda s: -s[0])
        return [(r["note_id"], r["text"]) for _, r in scored[:CANDIDATES]]

    @staticmethod
    def _passes(
        row: sqlite3.Row,
        types: list[str] | None,
        topic: str | None,
        valid_on: date | None,
        trust: list[str] | None,
    ) -> bool:
        if types and row["type"] not in types:
            return False
        if trust and row["trust"] not in trust:
            return False
        if topic and topic.lower() not in json.loads(row["topics"]):
            return False
        if valid_on is not None:
            start, end = row["valid_from"], row["valid_until"]
            if start and start[:10] > valid_on.isoformat():
                return False
            if end and end[:10] < valid_on.isoformat():
                return False
        return True

    def get(self, name_or_path: str) -> sqlite3.Row | None:
        row = self.conn.execute("SELECT * FROM notes WHERE path = ?", (name_or_path,)).fetchone()
        if row is None:
            row = self.conn.execute(
                "SELECT * FROM notes WHERE name = ? ORDER BY path LIMIT 1", (name_or_path.lower(),)
            ).fetchone()
        return row

    def related(self, name: str, depth: int = 2) -> tuple[list[dict[str, Any]], list[tuple]]:
        """Notes reachable through links in either direction, with their depth, and the
        edges among them; then the notes that share a topic with the root, marked
        ``via: topic``. A linked name with no note is reported as missing."""
        name = name.lower()
        nodes, edges = self._linked(name, depth)
        reached = {n["name"] for n in nodes}
        root = self.get(name)
        if root is not None:
            for topic in json.loads(root["topics"]):
                rows = self.conn.execute(
                    "SELECT name, title, type, path FROM notes WHERE name != ? AND EXISTS"
                    " (SELECT 1 FROM json_each(notes.topics) WHERE value = ?) ORDER BY name",
                    (name, topic),
                ).fetchall()
                for row in rows:
                    if row["name"] in reached:
                        continue
                    reached.add(row["name"])
                    nodes.append(
                        {
                            "name": row["name"],
                            "depth": 1,
                            "title": row["title"],
                            "type": row["type"],
                            "path": row["path"],
                            "via": f"topic {topic}",
                        }
                    )
        return nodes, edges

    def _linked(self, name: str, depth: int) -> tuple[list[dict[str, Any]], list[tuple]]:
        rows = self.conn.execute(
            """
            WITH RECURSIVE edges(src, dst) AS (
                SELECT n.name, l.to_name FROM links l JOIN notes n ON n.id = l.from_id
                UNION
                SELECT l.to_name, n.name FROM links l JOIN notes n ON n.id = l.from_id
            ),
            reach(name, depth) AS (
                SELECT ?, 0
                UNION
                SELECT e.dst, r.depth + 1 FROM reach r JOIN edges e ON e.src = r.name
                WHERE r.depth < ?
            )
            SELECT name, MIN(depth) AS depth FROM reach GROUP BY name ORDER BY depth, name
            """,
            (name, depth),
        ).fetchall()
        names = [r["name"] for r in rows]
        nodes = []
        for r in rows:
            note = self.conn.execute(
                "SELECT title, type, path FROM notes WHERE name = ? ORDER BY path LIMIT 1",
                (r["name"],),
            ).fetchone()
            nodes.append(
                {
                    "name": r["name"],
                    "depth": r["depth"],
                    "title": note["title"] if note else "",
                    "type": note["type"] if note else "missing",
                    "path": note["path"] if note else "",
                    "via": "link",
                }
            )
        if not names:
            return nodes, []
        marks = ",".join("?" * len(names))
        sql = (
            "SELECT DISTINCT n.name AS src, l.to_name AS dst FROM links l"
            " JOIN notes n ON n.id = l.from_id"
            " WHERE n.name IN (MARKS) AND l.to_name IN (MARKS)"
        ).replace("MARKS", marks)
        edges = self.conn.execute(sql, names + names).fetchall()
        return nodes, [(e["src"], e["dst"]) for e in edges]

    def stats(self) -> dict[str, Any]:
        q = self.conn.execute
        return {
            "notes": q("SELECT COUNT(*) FROM notes").fetchone()[0],
            "chunks": q("SELECT COUNT(*) FROM chunks").fetchone()[0],
            "embedded": q("SELECT COUNT(*) FROM chunks WHERE embedding IS NOT NULL").fetchone()[0],
            "links": q("SELECT COUNT(*) FROM links").fetchone()[0],
            "dangling_links": q(
                "SELECT COUNT(DISTINCT to_name) FROM links WHERE to_name NOT IN"
                " (SELECT name FROM notes)"
            ).fetchone()[0],
            "types": dict(q("SELECT type, COUNT(*) FROM notes GROUP BY type ORDER BY 2 DESC")),
            "embedder": (q("SELECT value FROM meta WHERE key='embedder'").fetchone() or [None])[0],
            "vector_extension": self.vec,
        }


STOPWORDS = frozenset(
    """le la les de des du un une et ou à au aux en dans sur pour par avec sans que qui quoi
    est sont ce cette ces cet ne pas plus mais donc car ni se sa son ses leur leurs nous vous
    ils elles je tu il elle on mon ma mes ton ta tes notre votre été être avoir fait faire
    comme tout tous toute toutes très bien aussi ici là the and or of to in on for with from
    this that these those is are was were be been being have has had do does did not can
    could would should will shall may might must its it's it as at by an a you your our
    their they them we he she his her my me i am about into than then there here what which
    who whom whose when where why how all any some each few more most other such only own
    same so too very just also please veux voudrais peux peut faut faudrait dois doit chez
    rappelle rappeler rappelle-moi dis dis-moi donne montre explique cherche trouve regarde
    vérifie sais savoir remind tell show find give know check look explain want need""".split()
)


def content_words(text: str) -> list[str]:
    return [t for t in TOKEN.findall(text.lower()) if len(t) > 2 and t not in STOPWORDS]


def fold(text: str) -> str:
    import unicodedata

    return unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()


def chunk(title: str, body: str, size: int = CHUNK_CHARS) -> list[str]:
    """Paragraphs packed up to ``size`` characters, each chunk led by the title so a
    paragraph keeps its subject once embedded on its own."""
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", body) if p.strip()]
    chunks: list[str] = []
    current = ""
    for para in paragraphs:
        while len(para) > size:
            if current:
                chunks.append(current)
                current = ""
            chunks.append(para[:size])
            para = para[size:]
        if current and len(current) + len(para) + 2 > size:
            chunks.append(current)
            current = para
        else:
            current = f"{current}\n\n{para}" if current else para
    if current:
        chunks.append(current)
    if not chunks:
        chunks.append("")
    return [f"{title}\n\n{c}".strip() for c in chunks]


def pack(vector: list[float]) -> bytes:
    return struct.pack(f"{len(vector)}f", *vector)


def unpack(blob: bytes) -> list[float]:
    return list(struct.unpack(f"{len(blob) // 4}f", blob))


def _under(path: str, root: Path) -> bool:
    try:
        Path(path).relative_to(root.resolve())
        return True
    except ValueError:
        return False


def _hit(row: sqlite3.Row, score: float, snippet: str) -> Hit:
    return Hit(
        path=row["path"],
        name=row["name"],
        title=row["title"],
        type=row["type"],
        trust=row["trust"],
        score=round(score, 5),
        snippet=" ".join((snippet or row["body"][:160]).split()),
        topics=json.loads(row["topics"]),
        valid_until=row["valid_until"],
        source=row["source"],
    )
