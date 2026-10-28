import pytest


@pytest.fixture(autouse=True)
def no_local_settings(tmp_path, monkeypatch):
    """The developer's own ~/.claude/kb/kb.env never reaches the tests."""
    monkeypatch.setenv("KB_ENV", str(tmp_path / "no-kb.env"))
