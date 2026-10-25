"""pr-watch's shared snapshot, against a fake GitHub API: two computers share their sections through
one branch, read each other's with a conditional request, fetch a host again only once its share is
too old, and leave alone a host they could not reach.

    python tests/pr-watch-shared.py [skills/pr-watch]
"""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time

from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class FakeGitHub(BaseHTTPRequestHandler):
    head = ""
    commits: dict[str, str] = {}
    trees: dict[str, str] = {}
    log: list[tuple[str, str, int]] = []

    def log_message(self, *args: object) -> None:
        pass

    def answer(self, code: int, body: object = None, etag: str = "") -> None:
        data = b"" if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(code)
        if etag:
            self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
        FakeGitHub.log.append((self.command, self.path.split("?")[0], code))

    def body(self) -> dict:
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")

    def do_GET(self) -> None:
        path = self.path.split("?")[0]
        if path.endswith("/git/ref/heads/pr-cache"):
            return self.answer(200, {"object": {"sha": self.head}}) if self.head else self.answer(404, {})
        if path.endswith("/contents/pr-watch/snapshot.json"):
            if not self.head:
                return self.answer(404, {})
            content = self.commits[self.head].encode()
            etag = '"' + hashlib.sha1(content).hexdigest() + '"'
            if self.headers.get("If-None-Match") == etag:
                return self.answer(304)
            return self.answer(200, content, etag)
        self.answer(404, {})

    def do_POST(self) -> None:
        path, body = self.path.split("?")[0], self.body()
        if path.endswith("/git/trees"):
            sha = hashlib.sha1(os.urandom(8)).hexdigest()
            FakeGitHub.trees[sha] = body["tree"][0]["content"]
            return self.answer(201, {"sha": sha})
        if path.endswith("/git/commits"):
            assert body["parents"] == [], "a shared snapshot commit has no parent"
            sha = hashlib.sha1(os.urandom(8)).hexdigest()
            FakeGitHub.commits[sha] = FakeGitHub.trees[body["tree"]]
            return self.answer(201, {"sha": sha})
        if path.endswith("/git/refs"):
            if self.head:
                return self.answer(422, {})
            FakeGitHub.head = body["sha"]
            return self.answer(201, {})
        self.answer(404, {})

    def do_PATCH(self) -> None:
        body = self.body()
        assert body.get("force") is True
        FakeGitHub.head = body["sha"]
        self.answer(200, {})


def load(skill: Path, root: Path):
    os.environ.update({"PR_WATCH_DIR": str(root / "sync" / "pr-watch"), "PR_WATCH_SHARED": "owner/sync",
                       "GITHUB_TOKEN": "test-token", "XDG_CACHE_HOME": str(root / "mac"),
                       "CLAUDE_CONFIG_DIR": str(root / "claude")})
    spec = importlib.util.spec_from_file_location("pr_watch", skill / "pr_watch.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def computer(pr, root: Path, name: str) -> None:
    """Switches the module to another computer's local copy."""
    pr._SHARED.clear()
    pr.SHARED_LOCAL = root / name / "pr-watch" / "shared.json"
    (root / "sync" / ".machine").write_text(name)


GITHUB_PR = "https://github.com/owner/app/pull/7"
ADO_PR = "https://dev.azure.com/org/project/_git/api/pullrequest/9"


def seen(title: str, state: str = "passed") -> dict:
    return {"title": title, "description": "", "status": "active", "target": "main", "source": "feat/x",
            "conflicts": False, "votes": {}, "comments": {}, "checks": {"ci": {"state": state, "required": None, "link": None}}}


def status(pr, mode: str) -> dict:
    out = io.StringIO()
    with redirect_stdout(out):
        pr.status(mode)
    return json.loads(out.getvalue())


def main() -> int:
    skill = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "skills" / "pr-watch")
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    os.environ["PR_WATCH_GITHUB_API"] = f"http://127.0.0.1:{server.server_address[1]}"
    root = Path(tempfile.mkdtemp())
    watch = root / "sync" / "pr-watch"
    watch.mkdir(parents=True)
    pr = load(skill, root)
    old = "2026-01-01T10:00Z"
    for url, title in ((GITHUB_PR, "app change"), (ADO_PR, "api change")):
        pr.save(pr.entry_path(url), {"url": url, "note": "", "added": old, "checked": old, "seen": seen(title)})
    (watch / "config.json").write_text(json.dumps({"azureOrgs": ["org"]}))

    # The hosts are faked: each fetch says what it was asked, and the Azure DevOps one can be cut.
    asked: list[str] = []
    reach = {"github": True, "ado": True}
    states = {"github": "passed", "ado": "passed"}

    def fetch_all(entries):
        rows = []
        for path, entry in entries:
            host = pr.host_of(entry["url"])
            asked.append(host)
            if reach[host]:
                rows.append((path, entry, seen(f"{host} fresh", states[host]), "me", ""))
            else:
                rows.append((path, entry, None, "", f"{host} unreachable"))
        return rows

    pr.fetch_all = fetch_all
    pr.auto_track = lambda entries, hosts=pr.HOSTS: ([], [])
    looked: list[str] = []

    def fetch_review_requests(entries, hosts=pr.HOSTS):
        looked.append("lists")
        return [], []

    runs: list[dict] = []

    def fetch_builds(entries, hosts=pr.HOSTS, only=None):
        looked.append("runs" if only is None else f"running runs {' '.join(only)}")
        return [row for row in runs if pr.host_of(row["url"]) in hosts], []

    pr.fetch_review_requests = fetch_review_requests
    pr.fetch_builds = fetch_builds
    pr.fetch_issues = lambda hosts=pr.HOSTS: ([], [])
    failures: list[str] = []

    def check(what: str, ok: bool) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {what}")
        if not ok:
            failures.append(what)

    def titles(answer: dict) -> dict:
        return {row["url"]: row["title"] for row in answer["prs"]}

    # 1. The Mac reaches GitHub only: it shares the github section, and ado stays unshared.
    computer(pr, root, "mac")
    reach["ado"] = False
    answer = status(pr, "auto")
    check("the mac fetches both hosts the first time", sorted(set(asked)) == ["ado", "github"])
    check("it shares github only", answer["fetched"] == ["github"] and FakeGitHub.head != "")
    check("its PR shows what it fetched", titles(answer)[GITHUB_PR] == "github fresh")
    check("the unreached host shows the record", titles(answer)[ADO_PR] == "api change")
    check("the share says who wrote it", answer["sections"]["github"]["by"] == "mac")

    # 2. Within the cache time, nothing is fetched, and the share is read with a 304 (once read
    # after this computer wrote it).
    status(pr, "auto")
    asked.clear()
    FakeGitHub.log.clear()
    pr._SHARED.clear()
    answer = status(pr, "auto")
    check("a fresh share is not fetched again", asked == [])
    check("an unreachable host is left alone for a while", "ado" not in asked)
    check("the share is read with a conditional request", ("GET", "/repos/owner/sync/contents/pr-watch/snapshot.json", 304) in FakeGitHub.log)

    # 3. The Windows PC reaches both: it fetches ado (no share yet), reads github from the Mac's share.
    computer(pr, root, "windows")
    reach["ado"] = True
    asked.clear()
    answer = status(pr, "auto")
    check("the pc fetches only the host nobody shared", asked == ["ado"])
    check("the pc shows the mac's github without asking github", titles(answer)[GITHUB_PR] == "github fresh")
    shared = json.loads(FakeGitHub.commits[FakeGitHub.head])["sections"]
    check("both sections are now shared", sorted(shared) == ["ado", "github"] and shared["github"]["by"] == "mac")

    # 4. Back on the Mac: a cached status reads the PC's ado section.
    computer(pr, root, "mac")
    answer = status(pr, "cached")
    check("the mac now shows the ado PR the pc fetched", titles(answer)[ADO_PR] == "ado fresh")

    def age(host: str, minutes: float) -> None:
        """Makes the host's share, every part of it, that old, here and on the branch."""
        local = pr.shared_local()
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - minutes * 60))
        section = local["sections"][host]
        section["at"] = stamp
        section["kinds"] = {kind: stamp for kind in section.get("kinds", {})}
        for one in section.get("prs", {}).values():
            one["at"] = stamp
        pr.save(pr.SHARED_LOCAL, local)
        FakeGitHub.commits[FakeGitHub.head] = json.dumps({"version": 1, "sections": local["sections"]})
        pr._SHARED.clear()

    # 5. Each part of a share gets old at its own pace, and any computer reaching the host fetches
    # it again: the PC here, as if the Mac were off. Past 6 minutes, only the look for new runs.
    computer(pr, root, "windows")
    age("github", 6)
    asked.clear()
    looked.clear()
    answer = status(pr, "auto")
    check("past 6 minutes, only new runs are looked for", asked == [] and looked == ["runs"])
    check("and shared as the pc's", answer["sections"]["github"]["by"] == "windows")
    # Past 11, the PRs too; the lists wait for 15.
    age("github", 11)
    asked.clear()
    looked.clear()
    status(pr, "auto")
    check("past 11 minutes, the PRs are read again, not the lists", asked == ["github"] and looked == ["runs"])
    age("github", 16)
    looked.clear()
    status(pr, "auto")
    check("past 16 minutes, the lists too", "lists" in looked)

    # 6. While a CI runs, only the PRs whose CI runs are read again, after `running` minutes (1 by default).
    states["github"] = "running"
    asked.clear()
    status(pr, "live")
    age("github", 3)
    asked.clear()
    looked.clear()
    status(pr, "auto")
    check("a share with a CI running is fetched again after 3 minutes", "github" in asked)
    check("and only what runs", looked == [])
    asked.clear()
    looked.clear()
    status(pr, "live")
    check("the refresh button reads everything, on every host", sorted(asked) == ["ado", "github"]
          and sorted(looked) == ["lists", "lists", "runs", "runs"])

    # A run in progress: after a minute, only its repo's runs are read again, the PRs left alone.
    states["github"] = "passed"
    run = "https://github.com/owner/app/actions/runs/7"
    runs.append({"url": run, "repo": "app", "pipeline": "Deploy", "number": "7", "branch": "main",
                 "status": "running", "queued": "2026-01-01T10:00Z", "started": "", "ended": ""})
    status(pr, "live")
    age("github", 2)
    asked.clear()
    looked.clear()
    status(pr, "auto")
    check("a run in progress is read again alone", asked == [] and looked == [f"running runs {run}"])
    (watch / "config.json").write_text(json.dumps({"azureOrgs": ["org"], "cacheMinutes": {"running": 5}}))
    age("github", 3)
    asked.clear()
    status(pr, "auto")
    check("cacheMinutes in config.json is followed", "github" not in asked)

    # 7. Turned off: nothing goes to GitHub.
    os.environ["PR_WATCH_SHARED"] = "off"
    FakeGitHub.log.clear()
    pr._SHARED.clear()
    status(pr, "live")
    check("PR_WATCH_SHARED=off sends nothing to the sync repo", FakeGitHub.log == [])

    server.shutdown()
    print(f"{len(failures)} failed" if failures else "all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
