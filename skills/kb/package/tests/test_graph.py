import json
import os
from datetime import date
from pathlib import Path

import pytest

from kb import cli
from kb.graph import Pair, last_dated, links_to_add, lint, similar_pairs
from kb.index import Index
from kb.notes import add_links, load_note, load_notes, parse_note
from kb.site import render, site_data

WAVES = "Waves, wind, swell and tide at the beach: the spot works with a west swell. "
BANK = "The business bank account, its IBAN and the monthly accounting export. "


@pytest.fixture
def base(tmp_path: Path, monkeypatch) -> tuple[Path, Path]:
    notes = tmp_path / "knowledge"
    memory = tmp_path / "memory-repos" / "github.com" / "me" / "surf-app"
    notes.mkdir()
    memory.mkdir(parents=True)
    (notes / "surf-spot.md").write_text(
        "---\nname: surf-spot\ntitle: Surf spot\ntype: fact\ntopics: [surf]\n---\n" + WAVES * 3
    )
    (notes / "surf-forecast.md").write_text(
        "---\nname: surf-forecast\ntitle: Surf forecast\ntopics: [surf]\nunlink: [bank]\n---\n"
        + WAVES * 3
    )
    (notes / "bank.md").write_text(
        "---\nname: bank\ntitle: Bank\nlinks: [accounting]\n---\n" + BANK
    )
    (memory / "swell-rules.md").write_text(
        "---\nname: swell-rules\ndescription: Swell rules\nmetadata:\n  type: project\n---\n"
        + WAVES * 3
    )
    monkeypatch.setenv("KB_NOTES", f"{notes}{os.pathsep}{tmp_path / 'memory-repos'}")
    monkeypatch.setenv("KB_DB", str(tmp_path / "idx.sqlite"))
    monkeypatch.setenv("KB_EMBED", "hash")
    assert cli.main(["index"]) == 0
    return notes, memory


def run(capsys, *argv: str) -> tuple[int, str]:
    code = cli.main(list(argv))
    return code, capsys.readouterr().out


def test_add_links_keeps_the_rest_of_the_file(tmp_path):
    path = tmp_path / "a.md"
    path.write_bytes(b"---\r\nname: a\r\n# kept\r\ntitle: A\r\n---\r\n\r\nBody [[b]].\r\n")
    assert add_links(path, ["c"])
    assert path.read_bytes() == (
        b"---\r\nname: a\r\n# kept\r\ntitle: A\r\nlinks: [c]\r\n---\r\n\r\nBody [[b]].\r\n"
    )
    assert add_links(path, ["d"])
    assert b"links: [c, d]\r\n" in path.read_bytes()
    block = tmp_path / "b.md"
    block.write_text("---\nname: b\nlinks:\n  - x\ntopics: [t]\n---\nBody\n")
    assert add_links(block, ["y"])
    note = load_note(block)
    assert note.links == ["x", "y"] and note.topics == ["t"]
    bare = tmp_path / "c.md"
    bare.write_text("No front matter\n")
    assert not add_links(bare, ["x"])


def test_similar_pairs_and_links_respect_folders_and_unlink(base, tmp_path):
    notes_dir, memory = base
    index = Index(tmp_path / "idx.sqlite")
    pairs = similar_pairs(index, 0.5)
    names = {frozenset((Path(p.a).stem, Path(p.b).stem)) for p in pairs}
    assert frozenset(("surf-spot", "surf-forecast")) in names
    assert frozenset(("surf-spot", "swell-rules")) in names
    notes = load_notes([notes_dir, tmp_path / "memory-repos"])
    plan = links_to_add(notes, pairs, notes_dir, 0.5)
    added = {(path.stem, dst) for path, items in plan.items() for dst, _ in items}
    assert all(path.parent == notes_dir for path in plan)
    assert ("surf-spot", "swell-rules") in added or ("surf-forecast", "swell-rules") in added
    assert not any(dst == "bank" for _, dst in added if _ == "surf-forecast")


def test_link_never_adds_twice(base, capsys, tmp_path):
    notes_dir, _ = base
    code, out = run(capsys, "link", "--min", "0.5")
    assert code == 0 and "→" in out and "add --apply" in out
    assert "links:" not in (notes_dir / "surf-spot.md").read_text()
    code, out = run(capsys, "link", "--min", "0.5", "--apply")
    assert "written" in out
    reports = list((notes_dir / ".curator").glob("*-links.md"))
    assert len(reports) == 1 and "move its name from `links` to `unlink`" in reports[0].read_text()
    assert run(capsys, "index")[0] == 0
    code, out = run(capsys, "link", "--min", "0.5", "--apply")
    assert code == 0 and out.strip() == "No link to add."


def test_related_lists_notes_that_read_alike(base, capsys):
    code, out = run(capsys, "related", "swell-rules")
    assert code == 0
    alike = out.split("Reads like:")[1]
    assert "surf-spot" in alike and "surf-forecast" in alike and "bank" not in alike
    code, out = run(capsys, "--json", "related", "surf-spot")
    via = {n["name"]: n["via"] for n in json.loads(out)["nodes"]}
    assert via["surf-forecast"] == "topic surf"
    assert via["swell-rules"].startswith("reads like ")


def test_link_without_vectors(tmp_path, monkeypatch, capsys):
    notes = tmp_path / "n"
    notes.mkdir()
    (notes / "a.md").write_text("---\nname: a\n---\nText\n")
    monkeypatch.setenv("KB_NOTES", str(notes))
    monkeypatch.setenv("KB_DB", str(tmp_path / "idx.sqlite"))
    monkeypatch.setenv("KB_EMBED", "none")
    assert cli.main(["index"]) == 0
    code, out = run(capsys, "link", "--apply")
    assert code == 0 and "needs the semantic search" in out


def test_lint_kinds():
    today = date(2026, 10, 28)
    notes = [
        parse_note(
            "---\nname: old\ntype: project\ncreated: 2026-01-02\n---\nBody\n", Path("old.md")
        ),
        parse_note(
            "---\nname: moved\ntype: project\ncreated: 2026-01-02\n---\n"
            "Body\n\n## 2026-10-01\n\nMore\n",
            Path("moved.md"),
        ),
        parse_note(
            "---\nname: over\ntype: decision\ncreated: 2026-01-02\n"
            "valid_until: 2026-02-01\n---\nB\n",
            Path("over.md"),
        ),
        parse_note("---\nname: a\nlinks: [ghost]\n---\nB\n", Path("a.md")),
        parse_note("---\nname: b\nlinks: [a]\n---\nB\n", Path("b.md")),
        parse_note("---\nname: Bad Name\n---\nB\n", Path("bad.md")),
        parse_note("---\nname: alike\n---\nB\n", Path("alike.md")),
    ]
    pairs = [
        Pair(str(Path("a.md").resolve()), str(Path("b.md").resolve()), 0.9),
        Pair(str(Path("alike.md").resolve()), str(Path("moved.md").resolve()), 0.6),
    ]
    findings = lint(notes, pairs, today)
    kinds = {(f.kind, f.name) for f in findings}
    assert ("stale", "old") in kinds
    assert ("stale", "moved") not in kinds and ("stale", "over") not in kinds
    assert ("dangling", "a") in kinds
    assert ("near-duplicate", "a") in kinds
    assert ("malformed", "bad name") in kinds
    assert ("orphan", "old") in kinds and ("orphan", "a") not in kinds
    assert ("orphan", "alike") not in kinds and ("near-duplicate", "alike") not in kinds
    assert last_dated(notes[1]) == date(2026, 10, 1)


def test_lint_judges_memory_notes_by_their_own_rules(tmp_path):
    mine, memory = tmp_path / "knowledge", tmp_path / "memory"
    notes = [
        parse_note("---\nname: kept\nlinks: [later]\n---\nB\n", mine / "kept.md"),
        parse_note("---\nname: shared\n---\nB\n", mine / "shared.md"),
        parse_note(
            "---\nname: User profile\ndescription: Who\n---\nB\n", memory / "user_profile.md"
        ),
        parse_note("---\nname: lone\nlinks: [later]\n---\nB\n", memory / "a" / "lone.md"),
        parse_note("---\nname: lone\n---\nB\n", memory / "b" / "lone.md"),
        parse_note("---\nname: shared\n---\nB\n", memory / "shared.md"),
    ]
    assert notes[2].name == "user_profile" and notes[2].title == "Who"
    findings = lint(notes, [], date(2026, 10, 28), writable=mine)
    kinds = {(f.kind, f.name, Path(f.path).parent.name) for f in findings}
    assert kinds == {
        ("dangling", "kept", "knowledge"),
        ("orphan", "shared", "knowledge"),
        ("same-name", "shared", "memory"),
    }


def test_lint_command(base, capsys):
    code, out = run(capsys, "--json", "lint")
    assert code == 0
    kinds = {(f["kind"], f["name"]) for f in json.loads(out)}
    assert ("dangling", "bank") in kinds and ("orphan", "swell-rules") not in kinds


def test_site_groups_escapes_and_links(base, tmp_path, capsys):
    notes_dir, memory = base
    (notes_dir / "evil.md").write_text(
        "---\nname: evil\ntitle: Evil\ntrust: third-party\ntopics: [surf-app]\n---\n"
        "</script><script>alert(1)</script> [[surf-spot]]\n"
    )
    assert cli.main(["index"]) == 0
    out = tmp_path / "site.html"
    code, text = run(capsys, "site", "--out", str(out))
    assert code == 0 and str(out) in text
    page = out.read_text()
    assert "</script><script>alert" not in page
    assert page.count("</script>") == 1
    data = json.loads(page.split("const D = ", 1)[1].split(";\n(() =>", 1)[0])
    by_name = {n["name"]: n for n in data["nodes"]}
    assert by_name["swell-rules"]["project"] == "surf-app"
    assert by_name["evil"]["project"] == "surf-app"
    assert by_name["surf-spot"]["project"] == "surf"
    ids = {n["name"]: i for i, n in enumerate(data["nodes"])}
    assert [ids["evil"], ids["surf-spot"]] in data["links"]
    assert any(f["kind"] == "dangling" and f["id"] == ids["bank"] for f in data["findings"])


def test_render_keeps_the_template_whole():
    data = site_data([], [], [], [], date(2026, 10, 28))
    page = render(data)
    assert "/*KB_DATA*/" not in page and '"generated":"2026-10-28"' in page
