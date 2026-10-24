from datetime import date
from pathlib import Path

import pytest

from kb.embed import HashEmbedder
from kb.index import Index, chunk
from kb.notes import load_notes


def write(root: Path, name: str, body: str, **meta: str) -> Path:
    lines = ["---", f"name: {name}"] + [f"{k}: {v}" for k, v in meta.items()] + ["---", "", body]
    path = root / f"{name}.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


@pytest.fixture
def notes(tmp_path: Path) -> Path:
    root = tmp_path / "knowledge"
    root.mkdir()
    write(
        root,
        "acme-accountant",
        "Acme Books est le cabinet comptable, contact Sam. Les mails concernent [[my-company]].",
        title="Acme Books est le cabinet comptable",
        trust="user",
        topics="[compta]",
    )
    write(
        root,
        "my-company",
        "My Company is the user's company. Its bank is [[qonto]].",
        title="My Company, the company",
        type="project",
    )
    write(root, "qonto", "Qonto holds the business account.", title="Qonto bank account")
    write(
        root,
        "old-accountant",
        "The accountant used to be Dupont & Co.",
        title="Former accountant",
        valid_until="2025-12-31",
    )
    return root


def make_index(tmp_path: Path, notes: Path, embedder=None) -> Index:
    index = Index(tmp_path / "idx.sqlite", embedder or HashEmbedder())
    index.update(load_notes([notes]), [notes])
    return index


def test_update_counts_and_incremental(tmp_path: Path, notes: Path):
    index = Index(tmp_path / "idx.sqlite", HashEmbedder())
    stats = index.update(load_notes([notes]), [notes])
    assert (stats.added, stats.changed, stats.removed) == (4, 0, 0)
    assert stats.chunks_embedded == 4
    stats = index.update(load_notes([notes]), [notes])
    assert (stats.added, stats.changed, stats.unchanged, stats.chunks_embedded) == (0, 0, 4, 0)
    (notes / "qonto.md").write_text("---\nname: qonto\n---\nQonto, changed.\n")
    (notes / "old-accountant.md").unlink()
    stats = index.update(load_notes([notes]), [notes])
    assert (stats.changed, stats.removed, stats.unchanged) == (1, 1, 2)
    assert index.stats()["notes"] == 3


def test_text_search_finds_exact_words_with_accents_folded(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    hits = index.search("cabinet comptable")
    assert hits[0].name == "acme-accountant"
    assert "[" in hits[0].snippet
    assert index.search("Sam")[0].name == "acme-accountant"


def test_vector_search_contributes(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    hits = index.search("business bank account")
    assert hits[0].name == "qonto"


def test_filters(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    assert [h.name for h in index.search("accountant", valid_on=date(2026, 10, 23))] == [
        "acme-accountant"
    ] or "old-accountant" not in [h.name for h in index.search("accountant", valid_on=date.today())]
    names_all = [h.name for h in index.search("accountant")]
    assert "old-accountant" in names_all
    assert [h.name for h in index.search("company", types=["project"])] == ["my-company"]
    assert [h.name for h in index.search("comptable", topic="compta")] == ["acme-accountant"]
    assert [h.name for h in index.search("comptable", trust=["user"])] == ["acme-accountant"]


def test_related_walks_links_both_ways(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    nodes, edges = index.related("qonto", depth=2)
    by_name = {n["name"]: n["depth"] for n in nodes}
    assert by_name == {"qonto": 0, "my-company": 1, "acme-accountant": 2}
    assert set(edges) == {("acme-accountant", "my-company"), ("my-company", "qonto")}
    nodes, _ = index.related("qonto", depth=1)
    assert {n["name"] for n in nodes} == {"qonto", "my-company"}


def test_dangling_link_reported(tmp_path: Path, notes: Path):
    write(notes, "lonely", "Points to [[nowhere]].")
    index = make_index(tmp_path, notes)
    assert index.stats()["dangling_links"] == 1
    nodes, _ = index.related("lonely")
    assert {n["name"]: n["type"] for n in nodes}["nowhere"] == "missing"


def test_brute_force_matches_extension(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    with_ext = [h.name for h in index.search("business bank account")]
    index.vec = False
    without = [h.name for h in index.search("business bank account")]
    assert with_ext[:2] == without[:2]
    assert set(with_ext) == set(without)


def test_model_change_reembeds(tmp_path: Path, notes: Path):
    make_index(tmp_path, notes).close()
    index = Index(tmp_path / "idx.sqlite", HashEmbedder(dim=64))
    stats = index.update(load_notes([notes]), [notes])
    assert stats.unchanged == 4
    assert stats.chunks_embedded == 4
    assert index.stats()["embedded"] == 4


def test_text_only_index(tmp_path: Path, notes: Path):
    index = Index(tmp_path / "idx.sqlite", None)
    index.update(load_notes([notes]), [notes])
    assert index.search("comptable")[0].name == "acme-accountant"
    assert index.search("zzz") == []


def test_precise_text_mode_matches_most_words_of_a_sentence(tmp_path: Path, notes: Path):
    index = make_index(tmp_path, notes)
    prompt = "peux-tu me rappeler qui est le cabinet comptable et le contact chez Acme Books"
    hits = index.search(prompt, mode="text")
    assert [h.name for h in hits] == ["acme-accountant"]
    assert index.search("mots absents de toutes les notes ici", mode="text") == []
    assert index.search("Sam", mode="text")[0].name == "acme-accountant"


def test_chunking_keeps_title_and_splits_long_text():
    chunks = chunk("Title", "para one\n\npara two", size=12)
    assert chunks == ["Title\n\npara one", "Title\n\npara two"]
    chunks = chunk("T", "x" * 50, size=20)
    assert len(chunks) == 3 and all(c.startswith("T\n\n") for c in chunks)
    assert chunk("Only title", "") == ["Only title"]
