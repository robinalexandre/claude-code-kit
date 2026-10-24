from pathlib import Path

from kb.notes import Note, iter_note_files, parse_front_matter, parse_note, slugify

CLAUDE_MEMORY = """---
name: vps-layout
description: Where home-agent runs and what must not be touched there
metadata:
  node_type: memory
  type: project
  originSessionId: b9d6bd51
  modified: 2026-10-22T14:46:40.018Z
---

home-agent runs on the shared VPS. See [[push-main-allowed]] and [[Takoon Bot|takoon-bot]].
"""

KB_NOTE = """---
name: acme-accountant
title: Acme Books is the accounting firm
type: fact
trust: user
source: user
topics: [compta, my-company]
created: 2026-10-22
valid_from: 2026-10-22
links: [my-holding]
---

Mails from Acme Books concern My Company or the holding.
"""


def test_claude_code_memory_reads_as_a_note():
    note = parse_note(CLAUDE_MEMORY, Path("/x/vps-layout.md"))
    assert note.name == "vps-layout"
    assert note.title.startswith("Where home-agent runs")
    assert note.type == "project"
    assert note.created == "2026-10-22"
    assert note.source == "b9d6bd51"
    assert note.links == ["push-main-allowed", "Takoon Bot"]
    assert note.body.startswith("home-agent runs")


def test_kb_note_fields():
    note = parse_note(KB_NOTE, Path("/x/acme.md"))
    assert note.trust == "user"
    assert note.topics == ["compta", "my-company"]
    assert note.valid_from == "2026-10-22"
    assert note.links == ["my-holding"]
    assert note.problems() == []


def test_note_without_front_matter_uses_heading_and_stem():
    note = parse_note("# A heading\n\nSome text.", Path("/x/some-note.md"))
    assert note.name == "some-note"
    assert note.title == "A heading"


def test_problems_reported():
    note = Note(name="Bad Name", title="", body="", type="rumor", trust="x", created="yesterday")
    problems = note.problems()
    assert any("slug" in p for p in problems)
    assert any("type" in p for p in problems)
    assert any("trust" in p for p in problems)
    assert any("created" in p for p in problems)
    assert any("title" in p for p in problems)


def test_round_trip_markdown():
    note = parse_note(KB_NOTE, Path("/x/acme.md"))
    again = parse_note(note.to_markdown(), Path("/x/acme.md"))
    assert again.name == note.name
    assert again.title == note.title
    assert again.topics == note.topics
    assert again.links == note.links
    assert again.body == note.body


def test_front_matter_edge_cases():
    meta, body = parse_front_matter('---\ntitle: "a: b"\nlist:\n  - one\n  - two\n---\nbody')
    assert meta == {"title": "a: b", "list": ["one", "two"]}
    assert body == "body"
    assert parse_front_matter("no front matter") == ({}, "no front matter")


def test_validity():
    from datetime import date

    note = Note(name="n", title="t", body="", valid_from="2026-01-01", valid_until="2026-06-30")
    assert note.is_valid_on(date(2026, 3, 1))
    assert not note.is_valid_on(date(2026, 7, 1))
    assert not note.is_valid_on(date(2025, 12, 31))


def test_iter_skips_indexes_and_hidden(tmp_path: Path):
    tmp_path = tmp_path / ".hidden-root" / "notes"
    tmp_path.mkdir(parents=True)
    (tmp_path / "MEMORY.md").write_text("index")
    (tmp_path / ".hidden").mkdir()
    (tmp_path / ".hidden" / "x.md").write_text("x")
    (tmp_path / "a.md").write_text("a")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "b.md").write_text("b")
    assert [p.name for p in iter_note_files(tmp_path)] == ["a.md", "b.md"]


def test_slugify():
    assert slugify("Ça wing & surf: été 2026") == "ca-wing-surf-ete-2026"
