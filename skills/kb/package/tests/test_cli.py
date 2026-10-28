import json
from pathlib import Path

import pytest

from kb import cli


class ExplodingEmbedder:
    """Fails on any use: proves a code path never touched the model."""

    name = "exploding"

    def embed(self, texts):
        raise AssertionError("the embedder was loaded")

    @property
    def dim(self):
        raise AssertionError("the embedder was loaded")


@pytest.fixture
def base(tmp_path: Path, monkeypatch) -> Path:
    notes = tmp_path / "knowledge"
    notes.mkdir()
    (notes / "acme.md").write_text(
        "---\nname: acme\ntitle: Acme Books accountant\ntopics: [compta]\n---\n"
        "Acme Books est le cabinet comptable. Contact Sam. " + "Long text. " * 100 + "\n"
    )
    (notes / "northbank.md").write_text(
        "---\nname: northbank\ntitle: Northbank account\ntopics: [compta, banque]\n---\n"
        "Northbank holds the business account. See [[acme]].\n"
    )
    (notes / "surf.md").write_text("---\nname: surf\ntitle: Surf spots\n---\nWaves and wind.\n")
    monkeypatch.setenv("KB_NOTES", str(notes))
    monkeypatch.setenv("KB_DB", str(tmp_path / "idx.sqlite"))
    monkeypatch.setenv("KB_EMBED", "hash")
    assert cli.main(["index"]) == 0
    return notes


def run(capsys, *argv: str) -> tuple[int, str]:
    code = cli.main(list(argv))
    return code, capsys.readouterr().out


def test_text_search_never_loads_the_model(base, capsys, monkeypatch):
    monkeypatch.setattr(cli, "get_embedder", lambda kind=None: ExplodingEmbedder())
    code, out = run(capsys, "search", "--text", "cabinet comptable")
    assert code == 0 and out.startswith("acme")
    code, out = run(capsys, "search", "-n", "1", "cabinet comptable")
    assert code == 0 and out.startswith("acme")


def test_auto_mode_falls_back_to_hybrid(base, capsys):
    code, out = run(capsys, "--json", "search", "business bank")
    assert code == 0
    assert json.loads(out)[0]["name"] == "northbank"


def test_show_brief_and_several(base, capsys):
    code, out = run(capsys, "show", "--brief", "acme", "northbank")
    assert code == 0
    assert out.startswith("# acme  [fact, agent]  Acme Books accountant")
    assert "topics: compta" in out
    assert "[…]" in out and len(out) < 1200
    assert "# northbank" in out
    code, out = run(capsys, "show", "nope")
    assert code == 1 and "Unknown note: nope" in out


def test_related_lists_links_then_topics(base, capsys):
    code, out = run(capsys, "related", "northbank")
    assert code == 0
    lines = out.splitlines()
    assert lines[0].startswith("northbank  [fact]")
    assert lines[1].startswith("  acme  [fact]")
    assert "Same topics:" not in out
    code, out = run(capsys, "related", "acme")
    assert "Same topics:" not in out
    (base / "urssaf.md").write_text("---\nname: urssaf\ntopics: [compta]\n---\nCharges.\n")
    assert cli.main(["index"]) == 0
    code, out = run(capsys, "related", "acme")
    assert "Same topics:" in out and "urssaf  [fact, topic compta]" in out
    code, out = run(capsys, "related", "acme", "--mermaid")
    assert out.splitlines()[0] == "mindmap"


def test_check_and_stats(base, capsys):
    code, out = run(capsys, "check")
    assert code == 0 and "nothing to report" in out
    code, out = run(capsys, "--json", "stats")
    assert json.loads(out)["notes"] == 3


def test_settings_file_fills_what_the_environment_leaves_unset(tmp_path, monkeypatch):
    env = tmp_path / "kb.env"
    env.write_text("# setup\nKB_EMBED=none\nKB_NOTES=/c/Users/me/knowledge\nKB_DB='x.sqlite'\nOTHER=1\n")
    monkeypatch.setenv("KB_DB", "kept.sqlite")
    for key in ("KB_EMBED", "KB_NOTES", "OTHER"):
        monkeypatch.delenv(key, raising=False)
    cli.load_settings(env)
    assert cli.os.environ["KB_EMBED"] == "none"
    assert cli.os.environ["KB_DB"] == "kept.sqlite"
    assert "OTHER" not in cli.os.environ
    expected = "C:/Users/me/knowledge" if cli.os.name == "nt" else "/c/Users/me/knowledge"
    assert cli.os.environ["KB_NOTES"] == expected
    for key in ("KB_EMBED", "KB_NOTES"):
        monkeypatch.delenv(key)
