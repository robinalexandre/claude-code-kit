import hashlib
import json
import statistics
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import pytest

from kb.embed import HashEmbedder
from kb.graph import collect, compose, refresh_map
from kb.index import Index
from kb.layout import SHELL, Item, Previous, _groups, _match_ids, group_count, place
from kb.notes import load_notes

NOW = datetime(2026, 11, 26, 14, 30, tzinfo=UTC)
THEMES = [
    ("sail", "wind boat harbour mast tide rope"),
    ("bake", "flour oven dough yeast crust butter"),
    ("code", "compiler test branch merge build lint"),
    ("garden", "seed soil water tomato compost spade"),
    ("music", "chord guitar tempo scale rhythm melody"),
    ("train", "rail station ticket platform carriage track"),
    ("chess", "pawn knight bishop castle opening endgame"),
    ("paint", "brush canvas colour easel palette stroke"),
    ("hike", "trail summit boots map ridge valley"),
    ("brew", "coffee grind roast kettle filter bean"),
]
FILLER = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima".split()


def pick(seed: str, words: list[str], count: int) -> list[str]:
    out = []
    for i in range(count):
        digest = hashlib.sha256(f"{seed}:{i}".encode()).digest()
        out.append(words[digest[0] % len(words)])
    return out


def write_notes(root: Path, count: int, start: int = 0) -> None:
    root.mkdir(parents=True, exist_ok=True)
    for n in range(start, start + count):
        theme, words = THEMES[n % len(THEMES)]
        text = " ".join(pick(f"w{n}", words.split(), 12) + pick(f"f{n}", FILLER, 3))
        links = f"\nSee [[{theme}-{n - len(THEMES)}]]." if n >= len(THEMES) and n % 4 == 0 else ""
        (root / f"{theme}-{n}.md").write_text(
            f"---\nname: {theme}-{n}\ntitle: {theme} {n}\ntopics: [{theme}]\n---\n{text}{links}\n"
        )


def build(root: Path, db: Path, embedder=None) -> Index:
    index = Index(db, embedder if embedder is not None else HashEmbedder())
    index.update(load_notes([root]), [root])
    return index


def test_the_same_notes_give_the_same_bytes(tmp_path):
    graphs = []
    for run in ("a", "b"):
        root = tmp_path / run / "knowledge"
        write_notes(root, 60)
        index = build(root, tmp_path / run / "idx.sqlite")
        graph, _ = compose(collect(index), None, NOW)
        graphs.append(json.dumps(graph, sort_keys=True))
    assert graphs[0] == graphs[1]
    graph = json.loads(graphs[0])
    assert graph["layout"]["method"] == "knn-force-3d" and graph["layout"]["status"] == "ready"
    assert all(len(node["pos"]) == 3 for node in graph["nodes"])
    assert "path" not in graph["nodes"][0] and graph["nodes"][0]["root"] == "knowledge"


def test_the_map_is_centred_and_scaled(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 120)
    graph, _ = compose(collect(build(root, tmp_path / "idx.sqlite")), None, NOW)
    points = np.array([node["pos"] for node in graph["nodes"]])
    radii = np.linalg.norm(points, axis=1)
    assert np.allclose(points.mean(axis=0), 0, atol=0.05)
    assert abs(np.percentile(radii, 95) - 1.0) < 0.01 and radii.max() <= 1.5 + 1e-6
    distances = np.linalg.norm(points[:, None] - points[None], axis=2) + np.eye(len(points))
    assert distances.min() > 1e-3


def test_adding_five_notes_barely_moves_the_others(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 250)
    index = build(root, tmp_path / "idx.sqlite")
    before, state = compose(collect(index), None, NOW)
    write_notes(root, 5, start=250)
    index.update(load_notes([root]), [root])
    after, _ = compose(collect(index), Previous.from_json(state), NOW)
    assert after["layout"]["full_at"] == before["layout"]["full_at"]
    old = {n["rel_path"]: n["pos"] for n in before["nodes"]}
    moves = [
        float(np.linalg.norm(np.array(n["pos"]) - np.array(old[n["rel_path"]])))
        for n in after["nodes"]
        if n["rel_path"] in old
    ]
    assert len(moves) == 250
    assert statistics.median(moves) < 0.03 and max(moves) < 0.15
    new = [n for n in after["nodes"] if n["rel_path"] not in old]
    assert len(new) == 5 and all(np.linalg.norm(n["pos"]) <= 1.5 + 1e-6 for n in new)


def test_many_new_notes_lay_the_map_out_again(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 40)
    index = build(root, tmp_path / "idx.sqlite")
    _, state = compose(collect(index), None, NOW)
    write_notes(root, 20, start=40)
    index.update(load_notes([root]), [root])
    later = datetime(2026, 11, 27, tzinfo=UTC)
    after, _ = compose(collect(index), Previous.from_json(state), later)
    assert after["layout"]["full_at"] == "2026-11-27T00:00:00Z"


def test_without_vectors_the_links_place_the_notes(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 30)
    index = Index(tmp_path / "idx.sqlite", None)
    index.update(load_notes([root]), [root])
    graph, _ = compose(collect(index), None, NOW)
    assert graph["layout"]["method"] == "links-force-3d" and graph["layout"]["embedder"] == ""
    assert all(node["pos"] is not None for node in graph["nodes"])


def test_a_note_without_a_vector_sits_by_its_links_or_on_the_shell(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 30)
    (root / "lonely.md").write_text("---\nname: lonely\n---\nNothing alike.\n")
    (root / "linked.md").write_text("---\nname: linked\n---\nSee [[sail-0]].\n")
    index = build(root, tmp_path / "idx.sqlite")
    index.conn.execute(
        "UPDATE chunks SET embedding = NULL WHERE note_id IN"
        " (SELECT id FROM notes WHERE name IN ('lonely', 'linked'))"
    )
    graph, _ = compose(collect(index), None, NOW)
    nodes = {n["name"]: n for n in graph["nodes"]}
    assert graph["layout"]["method"] == "knn-force-3d"
    assert abs(np.linalg.norm(nodes["lonely"]["pos"]) - SHELL) < 1e-3
    gap = np.linalg.norm(np.array(nodes["linked"]["pos"]) - np.array(nodes["sail-0"]["pos"]))
    assert gap < 0.05


def test_groups_follow_the_themes_and_keep_their_ids(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 120)
    index = build(root, tmp_path / "idx.sqlite")
    graph, state = compose(collect(index), None, NOW)
    assert len(graph["clusters"]) == group_count(120)
    assert all(c["size"] >= 3 and c["label"] for c in graph["clusters"])
    assert {c["id"] for c in graph["clusters"]} == {
        n["cluster"] for n in graph["nodes"] if n["cluster"]
    }
    (root / "sail-0.md").write_text(
        (root / "sail-0.md").read_text() + "\nOne more line about the harbour.\n"
    )
    index.update(load_notes([root]), [root])
    again, _ = compose(collect(index), Previous.from_json(state), NOW)
    assert {c["id"] for c in again["clusters"]} == {c["id"] for c in graph["clusters"]}
    for c in graph["clusters"]:
        other = next(o for o in again["clusters"] if o["id"] == c["id"])
        assert abs(other["size"] - c["size"]) <= 2


def test_a_group_under_three_notes_is_dissolved():
    rng = [((i * 37) % 11) / 1000 for i in range(40)]
    points, items = [], []
    centres = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0)]
    for g, centre in enumerate(centres):
        for i in range(10):
            points.append([c + rng[g * 10 + i] for c in centre])
            items.append(Item(key=f"g{g}-{i}", vector=None, topics=[f"t{g}"]))
    for i in range(2):
        points.append([0, 0, 5 + i * 0.01])
        items.append(Item(key=f"pair-{i}", vector=None))
    assigned, info, _ = _groups(items, np.array(points), None)
    assert assigned[-1] is None and assigned[-2] is None
    assert len(info) == 4 and sorted(c["label"] for c in info) == ["t0", "t1", "t2", "t3"]


def test_new_groups_take_the_ids_they_overlap_most():
    items = [Item(key=f"n{i}", vector=None) for i in range(9)]
    before = {"c4": {"n0", "n1", "n2"}, "c7": {"n3", "n4", "n5"}}
    assert _match_ids(items, [[3, 4, 5], [6, 7, 8], [0, 1, 2]], before) == ["c7", "c8", "c4"]


def test_two_roots_of_the_same_name_keep_apart(tmp_path):
    roots = [tmp_path / "a" / "notes", tmp_path / "b" / "notes"]
    for root in roots:
        write_notes(root, 12)
    index = Index(tmp_path / "idx.sqlite", HashEmbedder())
    index.update(load_notes(roots), roots)
    graph, state = compose(collect(index), None, NOW)
    assert len(graph["nodes"]) == 24 and len(state["positions"]) == 24
    again, _ = compose(collect(index), Previous.from_json(state), NOW)
    points = np.array([node["pos"] for node in again["nodes"]])
    distances = np.linalg.norm(points[:, None] - points[None], axis=2) + np.eye(len(points))
    assert distances.min() > 1e-3


def test_place_of_nothing_is_empty():
    placement = place([], [], "", None)
    assert placement.positions == [] and placement.group_info == []


def test_refresh_map_writes_both_files_and_reuses_them(tmp_path):
    root = tmp_path / "knowledge"
    write_notes(root, 20)
    index = build(root, tmp_path / "idx.sqlite")
    data_dir = tmp_path / "data"
    graph, _, changed = refresh_map(collect(index), data_dir, NOW)
    assert changed and (data_dir / "graph.json").exists() and (data_dir / "layout.json").exists()
    again, _, changed = refresh_map(collect(index), data_dir, NOW)
    assert not changed and again == graph
    text = (data_dir / "graph.json").read_text()
    assert str(tmp_path) not in text and str(tmp_path) not in (data_dir / "layout.json").read_text()


@pytest.mark.parametrize("damaged", ["{", "[]", '{"version": 1}'])
def test_a_damaged_layout_starts_over(tmp_path, damaged):
    root = tmp_path / "knowledge"
    write_notes(root, 20)
    index = build(root, tmp_path / "idx.sqlite")
    data_dir = tmp_path / "data"
    data_dir.mkdir()
    (data_dir / "layout.json").write_text(damaged)
    graph, _, changed = refresh_map(collect(index), data_dir, NOW)
    assert changed and len(graph["nodes"]) == 20
