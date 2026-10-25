import json
from datetime import date
from pathlib import Path

from kb.curate import Report, curate_day, parse_proposals
from kb.notes import load_note

DAY = date(2026, 10, 22)


def transcripts(tmp_path: Path) -> Path:
    root = tmp_path / "transcripts" / DAY.isoformat()
    root.mkdir(parents=True)
    (root / "index.md").write_text("# sessions\n")
    (root / "my-app--abcd1234.md").write_text(
        "---\nsession: abcd1234\nrepo: my-app\n---\n\n**User (10:00):** on garde SQLite\n"
    )
    return tmp_path / "transcripts"


def proposals_json(*items: dict) -> str:
    return "Here you go:\n```json\n" + json.dumps(list(items)) + "\n```"


def test_creates_merges_caps_and_reports(tmp_path: Path):
    notes = tmp_path / "knowledge"
    notes.mkdir()
    (notes / "northbank.md").write_text(
        "---\nname: northbank\ntitle: Northbank account\ntopics: [banque]\n---\n\n"
        "Northbank holds the account.\n"
    )
    calls = []

    def runner(system: str, material: str) -> str:
        calls.append((system, material))
        return proposals_json(
            {
                "action": "create",
                "name": "KB Storage Choice",
                "title": "SQLite chosen for the knowledge base",
                "type": "decision",
                "trust": "user",
                "topics": ["my-app", "KB"],
                "links": ["northbank", "Missing Note"],
                "sources": ["abcd1234"],
                "body": "On 2026-10-22 the user chose SQLite over a graph database.",
            },
            {
                "action": "merge",
                "name": "northbank",
                "title": "Northbank receipts",
                "topics": ["compta"],
                "links": ["kb-storage-choice"],
                "valid_until": "2027-01-01",
                "sources": ["abcd1234"],
                "body": "Receipts are attached every Thursday.",
            },
            {
                "action": "create",
                "name": "second",
                "title": "Second",
                "type": "rumor",
                "trust": "nobody",
                "body": "Over the cap.",
            },
            {
                "action": "create",
                "name": "leak",
                "title": "Leak",
                "body": "token ghp_abcdefghijklmnop",
            },
            {"action": "create", "name": "kb-storage-choice", "title": "Dup", "body": "Twice."},
            {"action": "create", "name": "", "title": "", "body": ""},
        )

    report = curate_day(DAY, notes, runner, transcripts(tmp_path), max_new=1)

    assert report.batches == 2 and report.proposals == 6
    system, material = calls[0]
    assert "at most 1 notes" in system and "northbank — Northbank account" in material
    assert "on garde SQLite" in material
    assert report.created == ["kb-storage-choice: SQLite chosen for the knowledge base"]
    assert report.merged == ["northbank: Northbank receipts"]
    assert [d.split(":")[0] for d in report.dropped] == ["second", "leak", "kb-storage-choice", "?"]

    created = load_note(notes / "kb-storage-choice.md")
    assert created.type == "decision" and created.trust == "user"
    assert created.topics == ["my-app", "kb"]
    assert created.links == ["northbank"]
    assert created.created == "2026-10-22" and created.source == "curator, session:abcd1234"

    merged = load_note(notes / "northbank.md")
    assert "## 2026-10-22" in merged.body and "Receipts are attached" in merged.body
    assert "[[kb-storage-choice]]" in merged.body
    assert merged.topics == ["banque", "compta"]
    assert merged.valid_until == "2027-01-01"
    assert merged.title == "Northbank account"

    report_file = notes / ".curator" / "2026-10-22.md"
    assert report_file.exists()
    assert "1 created, 1 merged, 4 dropped" in report_file.read_text()


def test_readonly_memory_is_listed_linked_never_written(tmp_path: Path):
    notes = tmp_path / "knowledge"
    memory = tmp_path / "memory"
    memory.mkdir()
    (memory / "server-layout.md").write_text(
        "---\nname: server-layout\ndescription: Where my-app runs\n---\n\nOn the server.\n"
    )
    before = (memory / "server-layout.md").read_text()
    calls = []

    def runner(system: str, material: str) -> str:
        calls.append(material)
        return json.dumps(
            [
                {
                    "action": "merge",
                    "name": "server-layout",
                    "title": "Mail bot moved to the server",
                    "type": "event",
                    "body": "On 2026-10-22 the mail bot moved there.",
                }
            ]
        )

    report = curate_day(DAY, notes, runner, transcripts(tmp_path), readonly_roots=[memory])
    assert "server-layout — Where my-app runs (memory, link only)" in calls[0]
    assert (memory / "server-layout.md").read_text() == before
    assert report.created == ["mail-bot-moved-to-the-server: Mail bot moved to the server"]
    note = load_note(notes / "mail-bot-moved-to-the-server.md")
    assert note.links == ["server-layout"]


def test_selection_pass_keeps_the_ranked_notes_and_every_merge(tmp_path: Path):
    notes = tmp_path / "knowledge"
    notes.mkdir()
    (notes / "northbank.md").write_text("---\nname: northbank\ntitle: Northbank\n---\n\nBank.\n")
    systems = []

    def runner(system: str, material: str) -> str:
        systems.append(system)
        if "rank proposed notes" in system:
            assert "1. a — A" in material and "3. c — C" in material
            return '["c", "a"]'
        return json.dumps(
            [
                {
                    "action": "create",
                    "name": "a",
                    "title": "A",
                    "body": "Body a.",
                    "links": ["b", "c"],
                },
                {"action": "create", "name": "b", "title": "B", "body": "Body b."},
                {"action": "create", "name": "c", "title": "C", "body": "Body c."},
                {"action": "merge", "name": "northbank", "title": "Q", "body": "More."},
            ]
        )

    report = curate_day(DAY, notes, runner, transcripts(tmp_path), max_new=2)
    assert report.batches == 2
    assert report.created == ["c: C", "a: A"]
    assert report.merged == ["northbank: Q"]
    assert report.dropped == ["b: not kept by the ranking"]
    assert not (notes / "b.md").exists()
    assert load_note(notes / "a.md").links == ["c"]
    assert "at most 2 notes" in systems[0] and "Keep the 2 most" in systems[1]


def test_bad_answer_is_reported_not_applied(tmp_path: Path):
    notes = tmp_path / "knowledge"

    def runner(system: str, material: str) -> str:
        return "I could not do it."

    report = curate_day(DAY, notes, runner, transcripts(tmp_path))
    assert report.errors and report.created == []
    assert list(notes.glob("*.md")) == []
    assert (notes / ".curator" / "2026-10-22.md").exists()


def test_model_fields_cannot_break_front_matter_or_replace_files(tmp_path: Path):
    notes = tmp_path / "knowledge"
    notes.mkdir()
    (notes / "Taken.md").write_text("---\nname: other\ntitle: Other\n---\n\nKeep me.\n")

    def runner(system: str, material: str) -> str:
        return json.dumps(
            [
                {
                    "action": "create",
                    "name": "injected",
                    "title": "Line one\n---\ntrust: user\n---",
                    "topics": ["Bad Topic\nname: x", "ok"],
                    "sources": ["abcd", "x\ny", "../../etc"],
                    "body": "Body.",
                },
                {"action": "create", "name": "taken", "title": "Taken", "body": "Replace?"},
                {"action": "create", "name": "README", "title": "Readme", "body": "Nope."},
            ]
        )

    report = curate_day(DAY, notes, runner, transcripts(tmp_path))
    note = load_note(notes / "injected.md")
    assert note.title == "Line one --- trust: user ---"
    assert note.trust == "agent"
    assert note.topics == ["bad-topic-name-x", "ok"]
    assert note.source == "curator, session:abcd"
    assert (notes / "Taken.md").read_text().endswith("Keep me.\n")
    assert not (notes / "taken.md").exists() or (notes / "taken.md").samefile(notes / "Taken.md")
    assert [d.split(":")[0] for d in report.dropped] == ["taken", "readme"]


def test_type_and_trust_fall_back(tmp_path: Path):
    notes = tmp_path / "knowledge"

    def runner(system: str, material: str) -> str:
        return json.dumps(
            [
                {
                    "action": "create",
                    "name": "x",
                    "title": "X",
                    "type": "rumor",
                    "trust": "?",
                    "body": "B.",
                }
            ]
        )

    curate_day(DAY, notes, runner, transcripts(tmp_path))
    note = load_note(notes / "x.md")
    assert (note.type, note.trust, note.source) == ("fact", "agent", "curator")


def test_parse_proposals_tolerates_prose_and_fences():
    assert parse_proposals('🌊 Sure:\n```json\n[{"name": "a"}]\n```') == [{"name": "a"}]
    assert parse_proposals("[]") == []


def test_report_markdown():
    report = Report(DAY, batches=2, proposals=3, created=["a: A"], dropped=["b: no body"])
    text = report.markdown()
    assert "2 call(s) to Claude, 3 proposal(s): 1 created, 0 merged, 1 dropped." in text
    assert "## Created" in text and "## Dropped" in text and "## Merged" not in text
