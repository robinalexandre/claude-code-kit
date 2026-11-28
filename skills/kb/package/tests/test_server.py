import json
import subprocess
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from kb.embed import HashEmbedder
from kb.server import Knowledge, clone_if_needed, git_env, make_server, pull

TOKEN = "s3cret-token-long-enough"


@pytest.fixture
def notes(tmp_path: Path) -> Path:
    root = tmp_path / "knowledge"
    root.mkdir()
    (root / "acme.md").write_text(
        "---\nname: acme\ntitle: Acme Books accountant\ntype: fact\ntrust: user\n"
        "topics: [compta]\n---\nAcme Books est le cabinet comptable. See [[northbank]].\n"
    )
    (root / "northbank.md").write_text(
        "---\nname: northbank\ntitle: Northbank account\ntopics: [compta, banque]\n"
        'source: "curator, session:abcd"\n---\nNorthbank holds the business account.\n'
    )
    (root / "rumor.md").write_text(
        "---\nname: rumor\ntitle: What the newsletter said\ntrust: third-party\n---\n"
        "The newsletter says Northbank raises its fees.\n"
    )
    return root


@pytest.fixture
def server(tmp_path: Path, notes: Path):
    knowledge = Knowledge(tmp_path / "idx.sqlite", HashEmbedder(), [notes, tmp_path / "absent"])
    knowledge.refresh()
    httpd = make_server(knowledge, TOKEN, "127.0.0.1", 0)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    yield f"http://127.0.0.1:{httpd.server_address[1]}", knowledge
    httpd.shutdown()
    httpd.server_close()


def get(base: str, path: str, token: str | None = TOKEN) -> tuple[int, dict]:
    request = urllib.request.Request(base + path)
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:  # noqa: S310 - local test server
            return resp.status, json.loads(resp.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read())


def test_health_is_open_and_everything_else_needs_the_token(server):
    base, _ = server
    assert get(base, "/health", token=None) == (200, {"ok": True})
    assert get(base, "/stats", token=None)[0] == 401
    assert get(base, "/stats", token="wrong-token-of-sixteen")[0] == 401
    status, stats = get(base, "/stats")
    assert status == 200 and stats["notes"] == 3 and stats["refreshed_at"]


def test_search_related_and_notes(server):
    base, _ = server
    status, data = get(base, "/search?q=cabinet+comptable&trust=user&trust=agent")
    assert status == 200
    names = [h["name"] for h in data["hits"]]
    assert names[0] == "acme" and "rumor" not in names
    assert data["hits"][0]["source"] == ""

    status, data = get(base, "/search?q=northbank&mode=text&n=1")
    assert status == 200 and len(data["hits"]) == 1
    assert data["hits"][0]["source"].startswith("curator")

    status, data = get(base, "/related?name=acme&depth=1")
    assert status == 200 and {n["name"] for n in data["nodes"]} == {"acme", "northbank"}
    assert data["edges"] == [["acme", "northbank"]]

    status, note = get(base, "/notes/northbank")
    assert status == 200 and note["title"] == "Northbank account"
    assert note["topics"] == ["compta", "banque"]
    assert "hash" not in note and "Northbank holds" in note["body"]
    assert get(base, "/notes/nobody")[0] == 404


def raw(base: str, path: str, headers: dict[str, str] | None = None) -> tuple[int, dict, bytes]:
    request = urllib.request.Request(base + path)
    request.add_header("Authorization", f"Bearer {TOKEN}")
    for key, value in (headers or {}).items():
        request.add_header(key, value)
    try:
        with urllib.request.urlopen(request, timeout=5) as resp:  # noqa: S310 - local test server
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as err:
        return err.code, dict(err.headers), err.read()


def test_the_graph_has_a_strong_etag_and_answers_304(server, tmp_path: Path):
    base, knowledge = server
    status, headers, body = raw(base, "/graph")
    graph = json.loads(body)
    assert status == 200 and headers["ETag"] == f'"{graph["rev"]}"'
    assert {n["name"] for n in graph["nodes"]} == {"acme", "northbank", "rumor"}
    assert graph["links"] and graph["layout"]["status"] == "ready"
    assert str(tmp_path) not in body.decode()
    for tag in (headers["ETag"], f"W/{headers['ETag']}", f'"other", {headers["ETag"]}', "*"):
        status, again, body = raw(base, "/graph", {"If-None-Match": tag})
        assert status == 304 and body == b"" and again["ETag"] == headers["ETag"]
    assert raw(base, "/graph", {"If-None-Match": '"other"'})[0] == 200
    assert (tmp_path / "graph.json").exists() and (tmp_path / "layout.json").exists()
    assert get(base, "/stats")[1]["graph_rev"] == graph["rev"]


def test_the_graph_changes_only_when_the_notes_do(server, notes: Path):
    base, knowledge = server
    rev = json.loads(raw(base, "/graph")[2])["rev"]
    assert knowledge.refresh_graph() is False
    (notes / "surf.md").write_text("---\nname: surf\ntitle: Surf spots\n---\nWaves.\n")
    knowledge.refresh()
    graph = json.loads(raw(base, "/graph")[2])
    assert graph["rev"] != rev and "surf" in {n["name"] for n in graph["nodes"]}


def test_a_restart_serves_the_stored_graph_before_any_refresh(tmp_path: Path, notes: Path):
    first = Knowledge(tmp_path / "idx.sqlite", HashEmbedder(), [notes])
    first.refresh()
    assert first.graph_served is not None
    again = Knowledge(tmp_path / "idx.sqlite", HashEmbedder(), [notes])
    assert again.graph_served == first.graph_served


def test_the_graph_is_503_until_it_is_built(tmp_path: Path, notes: Path):
    knowledge = Knowledge(tmp_path / "idx.sqlite", None, [notes])
    httpd = make_server(knowledge, TOKEN, "127.0.0.1", 0)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        assert raw(f"http://127.0.0.1:{httpd.server_address[1]}", "/graph")[0] == 503
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_notes_hits_and_related_carry_root_extra_and_dates(server, notes: Path):
    base, knowledge = server
    (notes / "spare.md").write_text(
        "---\nname: spare\ntitle: Spare parts [ ] list\nspace: perso\nowner: [a, b]\n"
        "valid_until: 2020-01-01\ntopics: [compta]\n---\n- [ ] array[0] of spare parts\n"
    )
    knowledge.refresh()
    status, note = get(base, "/notes/spare")
    assert status == 200 and note["root"] == "knowledge" and note["rel_path"] == "spare.md"
    assert note["extra"] == {"space": "perso"} and len(note["rev"]) == 12
    assert "hash" not in note and "rank" not in note

    hits = get(base, "/search?q=spare&mode=text&all=1")[1]["hits"]
    hit = next(h for h in hits if h["name"] == "spare")
    assert hit["root"] == "knowledge" and hit["extra"] == {"space": "perso"}
    assert hit["marks"] and all(hit["snippet"][a] == "[" for a, _ in hit["marks"])
    assert [hit["snippet"][a:b] for a, b in hit["marks"]] == ["[spare]"]
    assert "[ ]" in hit["snippet"] and "array[0]" in hit["snippet"]

    nodes = get(base, "/related?name=acme&depth=1")[1]["nodes"]
    spare = next(n for n in nodes if n["name"] == "spare")
    assert spare["valid_until"] == "2020-01-01" and spare["extra"] == {"space": "perso"}
    assert spare["root"] == "knowledge" and spare["via"] == "topic compta"


def test_a_shared_name_is_settled_by_root_order(tmp_path: Path):
    roots = [tmp_path / "zz-first", tmp_path / "aa-second"]
    for root, title in zip(roots, ("First root", "Second root"), strict=True):
        root.mkdir()
        (root / "same.md").write_text(f"---\nname: same\ntitle: {title}\n---\nBody.\n")
    knowledge = Knowledge(tmp_path / "idx.sqlite", None, roots)
    knowledge.refresh()
    note = knowledge.note("same")
    assert note is not None and note["title"] == "First root" and note["root"] == "zz-first"


def test_bad_requests_are_400_and_limits_are_clamped(server):
    base, _ = server
    assert get(base, "/search")[0] == 400
    assert get(base, "/search?q=x&mode=magic")[0] == 400
    assert get(base, "/search?q=x&n=abc")[0] == 400
    assert get(base, "/related")[0] == 400
    assert get(base, "/elsewhere")[0] == 404
    status, data = get(base, "/search?q=northbank&n=9999&mode=text")
    assert status == 200 and len(data["hits"]) <= 30


def test_refresh_picks_up_new_notes(server, notes: Path):
    base, knowledge = server
    (notes / "surf.md").write_text("---\nname: surf\ntitle: Surf spots\n---\nWaves and wind.\n")
    result = knowledge.refresh()
    assert result["added"] == 1 and result["notes"] == 4
    assert get(base, "/search?q=surf+spots&mode=text")[1]["hits"][0]["name"] == "surf"


def test_token_too_short_is_refused(tmp_path: Path, notes: Path):
    knowledge = Knowledge(tmp_path / "idx.sqlite", None, [notes])
    with pytest.raises(ValueError):
        make_server(knowledge, "short", "127.0.0.1", 0)


def test_git_token_travels_as_a_header_never_on_disk(tmp_path: Path):
    env = git_env("ghp_secret")
    assert env["GIT_CONFIG_KEY_0"] == "http.https://github.com/.extraheader"
    assert "ghp_secret" not in env["GIT_CONFIG_VALUE_0"]
    assert env["GIT_CONFIG_VALUE_0"].startswith("Authorization: Basic ")
    assert "GIT_CONFIG_COUNT" not in git_env(None)

    origin = tmp_path / "origin"
    subprocess.run(["git", "init", "-q", "-b", "main", str(origin)], check=True)
    (origin / "knowledge").mkdir()
    (origin / "knowledge" / "a.md").write_text("---\nname: a\ntitle: A\n---\nA.\n")
    subprocess.run(["git", "-C", str(origin), "add", "-A"], check=True)
    identity = ["-c", "user.name=t", "-c", "user.email=t@t"]
    subprocess.run(["git", "-C", str(origin), *identity, "commit", "-qm", "a"], check=True)
    clone = tmp_path / "clone"
    clone_if_needed(clone, origin.as_uri(), None)
    assert (clone / "knowledge" / "a.md").exists()
    clone_if_needed(clone, origin.as_uri(), None)
    assert pull(clone) == ""
    assert pull(tmp_path / "not-a-clone") == ""
