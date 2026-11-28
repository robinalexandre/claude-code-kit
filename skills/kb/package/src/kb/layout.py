"""Places on a 3D map for the notes, and the groups they form.

Distance on the map follows semantic distance, groups show, and a note does not move when
unrelated notes are added. ``numpy`` only, and no random number: the same notes give the
same map, byte for byte.

- Neighbour graph: each note's nearest notes by cosine, plus every explicit link.
- Full layout: the PCA projection to 3 dimensions as a start, then a force layout
  (springs along the neighbour graph, repulsion between all pairs, linear cooling), then
  centred and scaled so 95% of the notes sit within radius 1.
- Incremental layout: the notes already placed start where they were, tied there by an
  anchor spring and allowed to drift a little only; new notes start among their
  neighbours.
- Notes without a vector are placed from their links, else on an outer shell.
- Groups: a deterministic k-means on the positions, ids kept across runs by member overlap.
"""

from __future__ import annotations

import hashlib
import math
from collections import Counter
from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Any

import numpy as np

VERSION = 1
NEIGHBOURS = 8
FULL_ITERATIONS = 300
INCREMENTAL_ITERATIONS = 40
NEW_SHARE_FOR_FULL = 0.25
LINK_STRENGTH = 1.0
LINK_REST = 0.5
GRAVITY = 0.02
START_HEAT = 0.1
NEW_HEAT = 0.05
# The notes already placed move at most this far in one incremental run (map units).
PLACED_DRIFT = 0.02
TWIN_OFFSET = 0.01
SHELL = 1.3
CLAMP = 1.5
MIN_GROUP = 3
MAX_GROUPS = 16
LABEL_TOPICS = 2
GROUP_TOPICS = 8
GROUP_MATCH = 0.2
BLOCK = 512


@dataclass
class Item:
    """One note as the layout sees it. ``key`` is unique and stable (root, its rank when
    another root has the same name, and path)."""

    key: str
    vector: np.ndarray | None
    topics: list[str] = field(default_factory=list)
    project: str = ""
    degree: int = 0


@dataclass
class Previous:
    """What the last run left in ``layout.json``."""

    version: int
    method: str
    embedder: str
    scale: float
    full_keys: set[str]
    positions: dict[str, list[float]]
    groups: dict[str, set[str]]
    full_at: str | None = None

    @classmethod
    def from_json(cls, data: Any) -> Previous | None:
        try:
            return cls(
                version=int(data["version"]),
                method=str(data["method"]),
                embedder=str(data.get("embedder") or ""),
                scale=float(data["scale"]),
                full_keys=set(data["full_keys"]),
                positions={str(k): [float(x) for x in v] for k, v in data["positions"].items()},
                groups={str(k): set(v) for k, v in data["groups"].items()},
                full_at=data.get("full_at"),
            )
        except (KeyError, TypeError, ValueError, AttributeError):
            return None


@dataclass
class Placement:
    positions: list[list[float]]
    groups: list[str | None]
    group_info: list[dict[str, Any]]
    method: str
    full: bool
    scale: float
    full_keys: set[str]
    group_members: dict[str, set[str]]


def offset(key: str) -> np.ndarray:
    """A direction of length at most 1 derived from ``key``: reproducible, never random."""
    digest = hashlib.sha256(key.encode()).digest()
    values = [int.from_bytes(digest[i : i + 4], "little") / 0xFFFFFFFF for i in (0, 4, 8)]
    return np.array([2 * v - 1 for v in values])


def direction(key: str) -> np.ndarray:
    vector = offset(key)
    norm = np.linalg.norm(vector)
    return vector / norm if norm else np.array([1.0, 0.0, 0.0])


def neighbour_edges(vectors: np.ndarray, k: int = NEIGHBOURS) -> dict[tuple[int, int], float]:
    """Each row's ``k`` nearest rows by cosine (rows are unit vectors), as undirected
    pairs with their score. One matrix product per block of rows."""
    n = len(vectors)
    edges: dict[tuple[int, int], float] = {}
    if n < 2:
        return edges
    k = min(k, n - 1)
    for start in range(0, n, BLOCK):
        sims = vectors[start : start + BLOCK] @ vectors.T
        for row, scores in enumerate(sims):
            i = start + row
            scores = scores.copy()
            scores[i] = -np.inf
            order = np.argsort(-scores, kind="stable")[:k]
            for j in order:
                key = (min(i, int(j)), max(i, int(j)))
                edges[key] = max(edges.get(key, 0.0), max(float(scores[j]), 0.01))
    return edges


def pca3(vectors: np.ndarray) -> np.ndarray:
    """The projection on the three main axes, each axis's sign set so that its largest
    component is positive."""
    centred = vectors - vectors.mean(axis=0)
    _, _, vt = np.linalg.svd(centred, full_matrices=False)
    axes = vt[:3]
    for row in axes:
        if row[np.argmax(np.abs(row))] < 0:
            row *= -1
    projected = centred @ axes.T
    if projected.shape[1] < 3:
        projected = np.hstack([projected, np.zeros((len(projected), 3 - projected.shape[1]))])
    return projected


def normalise(points: np.ndarray) -> tuple[np.ndarray, float]:
    """Centred, 95% within radius 1, none beyond 1.5; and the factor applied."""
    if not len(points):
        return points, 1.0
    points = points - points.mean(axis=0)
    radii = np.linalg.norm(points, axis=1)
    p95 = float(np.percentile(radii, 95))
    scale = 1.0 / p95 if p95 > 1e-12 else 1.0
    points = points * scale
    radii = radii * scale
    far = radii > CLAMP
    points[far] *= (CLAMP / radii[far])[:, None]
    return points, scale


def force_layout(
    start: np.ndarray,
    edges: Sequence[tuple[int, int, float, float]],
    iterations: int,
    heat: np.ndarray,
    anchors: np.ndarray | None = None,
    anchored: np.ndarray | None = None,
) -> np.ndarray:
    """Springs along ``edges`` (i, j, strength, rest length), repulsion between all pairs,
    a light pull to the centre, linear cooling. ``heat`` caps each point's step at the
    first iteration; ``anchored`` points are also pulled back to ``anchors``."""
    points = start.astype(np.float64).copy()
    n = len(points)
    if n < 2 or iterations <= 0:
        return points
    k = (4.0 / n) ** (1 / 3)
    if edges:
        src = np.array([e[0] for e in edges])
        dst = np.array([e[1] for e in edges])
        strength = np.array([e[2] for e in edges])
        rest = np.array([e[3] for e in edges]) * k
    for step in range(iterations):
        forces = -GRAVITY * points
        for begin in range(0, n, BLOCK):
            block = points[begin : begin + BLOCK]
            delta = block[:, None, :] - points[None, :, :]
            dist2 = np.einsum("ijk,ijk->ij", delta, delta) + 1e-9
            forces[begin : begin + BLOCK] += k * k * np.einsum("ijk,ij->ik", delta, 1 / dist2)
        if edges:
            delta = points[dst] - points[src]
            dist = np.sqrt(np.einsum("ij,ij->i", delta, delta)) + 1e-9
            pull = (strength * (dist - rest) / dist)[:, None] * delta
            np.add.at(forces, src, pull)
            np.add.at(forces, dst, -pull)
        if anchors is not None and anchored is not None:
            forces[anchored] -= (points[anchored] - anchors[anchored]) * 1.0
        size = np.linalg.norm(forces, axis=1)
        cap = heat * (1 - step / iterations)
        factor = np.where(size > cap, cap / np.maximum(size, 1e-12), 1.0)
        points += forces * factor[:, None]
    return points


def place(
    items: list[Item],
    links: Sequence[tuple[int, int]],
    embedder: str,
    previous: Previous | None,
) -> Placement:
    """Positions and groups for ``items`` (in their order)."""
    n = len(items)
    keys = [item.key for item in items]
    with_vector = [i for i, item in enumerate(items) if item.vector is not None]
    method = "knn-force-3d" if with_vector else "links-force-3d"
    known = set(previous.positions) if previous else set()
    new = [key for key in keys if key not in known]
    full = (
        previous is None
        or previous.version != VERSION
        or previous.method != method
        or previous.embedder != embedder
        or (n and len([k for k in keys if k not in previous.full_keys]) > NEW_SHARE_FOR_FULL * n)
        or len(new) == n
    )
    points = np.zeros((n, 3))
    if n:
        if method == "knn-force-3d":
            points, scale = _place_vectors(items, with_vector, links, previous, full)
        else:
            points, scale = _place_links(items, links, previous, full)
    else:
        scale = 1.0
    positions = [[round(float(x), 4) + 0.0 for x in p] for p in points]
    full_keys = set(keys) if full else (previous.full_keys if previous else set(keys))
    groups, info, members = _groups(items, np.array(positions).reshape(n, 3), previous)
    return Placement(positions, groups, info, method, bool(full), scale, full_keys, members)


def _edges(
    items: list[Item], subset: list[int], links: Sequence[tuple[int, int]]
) -> list[tuple[int, int, float, float]]:
    """The neighbour graph over ``subset`` in its local indexes: nearest notes with their
    cosine as strength, explicit links stronger and shorter."""
    local = {g: i for i, g in enumerate(subset)}
    merged: dict[tuple[int, int], tuple[float, float]] = {}
    vectors = [items[g].vector for g in subset]
    if vectors and all(v is not None for v in vectors):
        matrix = np.array(vectors, dtype=np.float64)
        for (a, b), score in neighbour_edges(matrix).items():
            merged[(a, b)] = (score, 1.0)
    for a, b in links:
        if a in local and b in local and a != b:
            pair = (min(local[a], local[b]), max(local[a], local[b]))
            merged[pair] = (LINK_STRENGTH, LINK_REST)
    return [(a, b, s, r) for (a, b), (s, r) in sorted(merged.items())]


def _place_vectors(
    items: list[Item],
    with_vector: list[int],
    links: Sequence[tuple[int, int]],
    previous: Previous | None,
    full: bool,
) -> tuple[np.ndarray, float]:
    n = len(items)
    edges = _edges(items, with_vector, links)
    count = len(with_vector)
    if full or previous is None:
        matrix = np.array([items[g].vector for g in with_vector], dtype=np.float64)
        start, _ = normalise(pca3(matrix))
        start = start + np.array([offset(items[g].key) for g in with_vector]) * 1e-3
        heat = np.full(count, START_HEAT)
        laid = force_layout(start, edges, FULL_ITERATIONS, heat)
        placed, scale = normalise(laid)
    else:
        scale = previous.scale
        start = np.zeros((count, 3))
        anchored = np.zeros(count, dtype=bool)
        for i, g in enumerate(with_vector):
            old = previous.positions.get(items[g].key)
            if old is not None:
                start[i] = np.array(old) / scale
                anchored[i] = True
        neighbours: dict[int, list[tuple[int, float]]] = {}
        for a, b, s, _ in edges:
            neighbours.setdefault(a, []).append((b, s))
            neighbours.setdefault(b, []).append((a, s))
        for i, g in enumerate(with_vector):
            if anchored[i]:
                continue
            near = [(j, s) for j, s in neighbours.get(i, []) if anchored[j]]
            total = sum(s for _, s in near)
            if total > 0:
                centre = sum(start[j] * s for j, s in near) / total
            else:
                centre = direction(items[g].key) * (1.0 / scale)
            start[i] = centre + offset(items[g].key) * (TWIN_OFFSET / scale)
        anchors = start.copy()
        heat = np.where(
            anchored, 2 * PLACED_DRIFT / INCREMENTAL_ITERATIONS / scale, NEW_HEAT / scale
        )
        laid = force_layout(start, edges, INCREMENTAL_ITERATIONS, heat, anchors, anchored)
        placed = laid * scale
        radii = np.linalg.norm(placed, axis=1)
        far = radii > CLAMP
        placed[far] *= (CLAMP / radii[far])[:, None]
    points = np.zeros((n, 3))
    for i, g in enumerate(with_vector):
        points[g] = placed[i]
    _place_without_vectors(items, set(with_vector), links, previous, points)
    return points, scale


def _place_without_vectors(
    items: list[Item],
    placed: set[int],
    links: Sequence[tuple[int, int]],
    previous: Previous | None,
    points: np.ndarray,
) -> None:
    """A note without a vector keeps its last place, else sits at the mean of the notes it
    links to (or that link to it), else on the outer shell."""
    linked: dict[int, list[int]] = {}
    for a, b in links:
        linked.setdefault(a, []).append(b)
        linked.setdefault(b, []).append(a)
    for i, item in enumerate(items):
        if i in placed:
            continue
        old = previous.positions.get(item.key) if previous else None
        near = [j for j in linked.get(i, []) if j in placed]
        if old is not None:
            points[i] = old
        elif near:
            points[i] = points[near].mean(axis=0) + offset(item.key) * TWIN_OFFSET
        else:
            points[i] = direction(item.key) * SHELL


def _place_links(
    items: list[Item],
    links: Sequence[tuple[int, int]],
    previous: Previous | None,
    full: bool,
) -> tuple[np.ndarray, float]:
    """No note has a vector: a force layout along the links alone."""
    n = len(items)
    edges = _edges(items, list(range(n)), links)
    if full or previous is None:
        start = np.array(
            [direction(item.key) * (0.5 + 0.5 * abs(offset(item.key)[0])) for item in items]
        )
        laid = force_layout(start, edges, FULL_ITERATIONS, np.full(n, START_HEAT))
        return normalise(laid)
    scale = previous.scale
    start = np.zeros((n, 3))
    anchored = np.zeros(n, dtype=bool)
    for i, item in enumerate(items):
        old = previous.positions.get(item.key)
        if old is not None:
            start[i] = np.array(old) / scale
            anchored[i] = True
        else:
            start[i] = direction(item.key) * (SHELL / scale)
    heat = np.where(anchored, 2 * PLACED_DRIFT / INCREMENTAL_ITERATIONS / scale, NEW_HEAT / scale)
    laid = force_layout(start, edges, INCREMENTAL_ITERATIONS, heat, start.copy(), anchored)
    placed = laid * scale
    radii = np.linalg.norm(placed, axis=1)
    far = radii > CLAMP
    placed[far] *= (CLAMP / radii[far])[:, None]
    return placed, scale


def group_count(n: int) -> int:
    return min(n, max(3, min(MAX_GROUPS, round(math.sqrt(n / 2)))))


def kmeans(points: np.ndarray, k: int, first: int, rounds: int = 100) -> np.ndarray:
    """Lloyd's k-means seeded by farthest-point selection from ``first``: no randomness,
    ties go to the lowest index."""
    centres = [points[first]]
    nearest = np.sum((points - points[first]) ** 2, axis=1)
    while len(centres) < k:
        pick = int(np.argmax(nearest))
        centres.append(points[pick])
        nearest = np.minimum(nearest, np.sum((points - points[pick]) ** 2, axis=1))
    centre = np.array(centres)
    labels = np.full(len(points), -1)
    for _ in range(rounds):
        dist = np.sum((points[:, None, :] - centre[None, :, :]) ** 2, axis=2)
        fresh = np.argmin(dist, axis=1)
        if np.array_equal(fresh, labels):
            break
        labels = fresh
        for c in range(k):
            members = points[labels == c]
            if len(members):
                centre[c] = members.mean(axis=0)
    return labels


def _groups(
    items: list[Item], points: np.ndarray, previous: Previous | None
) -> tuple[list[str | None], list[dict[str, Any]], dict[str, set[str]]]:
    n = len(items)
    if n < MIN_GROUP:
        return [None] * n, [], {}
    first = min(range(n), key=lambda i: (-items[i].degree, i))
    labels = kmeans(points, group_count(n), first)
    found = []
    for c in sorted(set(labels.tolist()), key=lambda c: int(np.argmax(labels == c))):
        members = [i for i in range(n) if labels[i] == c]
        if len(members) >= MIN_GROUP:
            found.append(members)
    ids = _match_ids(items, found, previous.groups if previous else {})
    assigned: list[str | None] = [None] * n
    info = []
    group_members: dict[str, set[str]] = {}
    overall = Counter(t for item in items for t in set(item.topics))
    for gid, members in zip(ids, found, strict=True):
        for i in members:
            assigned[i] = gid
        group_members[gid] = {items[i].key for i in members}
        centroid = points[members].mean(axis=0)
        distances = np.linalg.norm(points[members] - centroid, axis=1)
        topics = _topics(items, members, overall, n)
        label = " · ".join(topics[:LABEL_TOPICS]) or _majority_project(items, members)
        info.append(
            {
                "id": gid,
                "label": label,
                "topics": topics[:GROUP_TOPICS],
                "size": len(members),
                "centroid": [round(float(x), 4) + 0.0 for x in centroid],
                "radius": round(float(np.percentile(distances, 80)), 4),
            }
        )
    info.sort(key=lambda g: _id_number(g["id"]))
    return assigned, info, group_members


def _id_number(gid: str) -> int:
    try:
        return int(gid[1:])
    except ValueError:
        return 0


def _match_ids(items: list[Item], found: list[list[int]], before: dict[str, set[str]]) -> list[str]:
    """Each new group takes the id of the old group it shares most members with (greedy,
    largest overlap first, a Jaccard index of at least 0.2); the others get new ids."""
    candidates = []
    for g, members in enumerate(found):
        keys = {items[i].key for i in members}
        for gid, old in before.items():
            common = len(keys & old)
            if common and common / len(keys | old) >= GROUP_MATCH:
                candidates.append((-common, g, _id_number(gid), gid))
    ids: list[str | None] = [None] * len(found)
    used: set[str] = set()
    for _, g, _, gid in sorted(candidates):
        if ids[g] is None and gid not in used:
            ids[g] = gid
            used.add(gid)
    next_number = max([_id_number(gid) for gid in before] + [0]) + 1
    out = []
    for gid in ids:
        if gid is None:
            gid = f"c{next_number}"
            next_number += 1
        out.append(gid)
    return out


def _topics(items: list[Item], members: list[int], overall: Counter[str], n: int) -> list[str]:
    """The group's topics, most specific first: frequency in the group over frequency
    overall. A topic only one member has counts only when no topic is shared."""
    inside = Counter(t for i in members for t in set(items[i].topics))
    if not inside:
        return []
    floor = 2 if max(inside.values()) >= 2 else 1
    size = len(members)
    scored = [
        ((count / size) / (overall[t] / n), count, t)
        for t, count in inside.items()
        if count >= floor
    ]
    scored.sort(key=lambda s: (-s[0], -s[1], s[2]))
    return [t for _, _, t in scored]


def _majority_project(items: list[Item], members: list[int]) -> str:
    projects = Counter(items[i].project for i in members if items[i].project)
    if not projects:
        return ""
    return sorted(projects.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
