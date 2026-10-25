"""pr-watch's followed issues, against a fake GitHub API: the issues the user is subscribed to are
listed (pull requests left out), a first sight is only recorded, then new comments by others, a close
or a reopen and label changes are reported, kept unread by a quiet check, cleared by `read`; the
pane's settings turn them off and set the pipeline runs kept per repo; an issue unfollowed is no
longer shown until `add` follows it again.

    python tests/pr-watch-issues.py [skills/pr-watch]
"""

from __future__ import annotations

import importlib.util
import io
import json
import os
import sys
import tempfile
import threading

from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ISSUE = "https://github.com/owner/app/issues/5"
PULL = "https://github.com/owner/app/pull/6"
ELSEWHERE = "https://github.com/someone/list/issues/9"


class FakeGitHub(BaseHTTPRequestHandler):
    issue: dict = {}
    elsewhere: dict = {}
    comments: list[dict] = []
    asked: list[str] = []

    def log_message(self, *args: object) -> None:
        pass

    def answer(self, body: object) -> None:
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self) -> None:
        FakeGitHub.asked.append(self.path)
        path, _, query = self.path.partition("?")
        pull = {"html_url": PULL, "pull_request": {}, "title": "a PR", "state": "open"}
        if path == "/issues":
            assert "filter=subscribed" in query
            wanted = "open" if "state=open" in query else "closed"
            return self.answer([one for one in (self.issue, pull) if one.get("state") == wanted])
        if path == "/search/issues":
            # The search finds the issue opened in someone else's repo, which the subscribed list misses.
            wanted = "open" if "is%3Aopen" in query else "closed"
            return self.answer({"items": [one for one in (self.issue, self.elsewhere, pull) if one.get("state") == wanted]})
        if path == "/repos/owner/app/issues/5/comments":
            since = query.split("since=")[1].split("&")[0]
            return self.answer([one for one in self.comments if one["created_at"] > since])
        self.answer([])


def issue(state: str, updated: str, comments: int, labels: list[str], reason: str | None = None) -> dict:
    return {"html_url": ISSUE, "title": "Crash on start", "user": {"login": "grace"}, "state": state,
            "state_reason": reason, "labels": [{"name": name} for name in labels], "comments": comments,
            "updated_at": updated, "closed_at": updated if state == "closed" else None}


def comment(author: str, at: str, text: str) -> dict:
    return {"user": {"login": author}, "created_at": at, "body": text}


def run(pr, function, *args) -> str:
    out = io.StringIO()
    with redirect_stdout(out):
        function(*args)
    return out.getvalue()


def main() -> int:
    skill = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "skills" / "pr-watch")
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeGitHub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    root = Path(tempfile.mkdtemp())
    os.environ.update({"PR_WATCH_DIR": str(root / "pr-watch"), "PR_WATCH_SHARED": "off", "GITHUB_TOKEN": "test-token",
                       "XDG_CACHE_HOME": str(root / "cache"), "CLAUDE_CONFIG_DIR": str(root / "claude"),
                       "PR_WATCH_GITHUB_API": f"http://127.0.0.1:{server.server_address[1]}"})
    spec = importlib.util.spec_from_file_location("pr_watch", skill / "pr_watch.py")
    pr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pr)
    pr._GITHUB_ME.append("me")
    pr.fetch_all = lambda entries: []
    pr.auto_track = lambda entries, hosts=pr.HOSTS: ([], [])
    pr.fetch_review_requests = lambda entries, hosts=pr.HOSTS: ([], [])
    pr.fetch_builds = lambda entries, hosts=pr.HOSTS: ([], [])
    failures: list[str] = []

    def check(what: str, ok: bool) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {what}")
        if not ok:
            failures.append(what)

    def status() -> dict:
        return json.loads(run(pr, pr.status, "cached"))

    # 1. First sight: recorded, nothing reported; the PR the same list returns is left out.
    FakeGitHub.issue = issue("open", "2026-10-20T10:00:00Z", 1, ["bug"])
    FakeGitHub.comments = [comment("grace", "2026-10-20T10:00:00Z", "It crashes.")]
    FakeGitHub.elsewhere = {**issue("closed", "2026-10-19T10:00:00Z", 0, [], "completed"), "html_url": ELSEWHERE}
    out = run(pr, pr.check, False)
    check("a new issue is only recorded", out.strip() == "No change.")
    listed = status()["issues"]
    check("status lists the followed issues once each, not the PR", [row["url"] for row in listed] == [ISSUE, ELSEWHERE])
    check("with its state, labels and no change", listed[0]["state"] == "open" and listed[0]["labels"] == ["bug"]
          and listed[0]["changes"] == [])
    FakeGitHub.elsewhere = {}

    # 2. A comment by someone else and a label: reported; the user's own comment is not.
    FakeGitHub.issue = issue("open", "2026-10-21T09:00:00Z", 3, ["bug", "triage"])
    FakeGitHub.comments += [comment("me", "2026-10-21T08:00:00Z", "Which version?"),
                            comment("ada", "2026-10-21T09:00:00Z", "2.1, on\x1b\x9b macOS.")]
    out = run(pr, pr.check, False)
    check("a new comment by another is reported", f"app #5 (Crash on start): new comment by ada: 2.1, on macOS. {ISSUE}" in out)
    check("its control characters left out", "\x1b" not in out and "\x9b" not in out)
    check("a label added is reported", "labeled triage" in out)
    check("the user's own comment is not", "Which version" not in out)
    check("comments are read only for an issue that has new ones",
          sum("/comments" in path for path in FakeGitHub.asked) == 1)
    out = run(pr, pr.check, False)
    check("seen once, not reported again", out.strip() == "No change.")
    FakeGitHub.elsewhere = {**issue("open", "2026-10-21T10:00:00Z", 4, []), "html_url": ELSEWHERE, "title": "Old thread"}
    out = run(pr, pr.check, False)
    check("an issue that shows up after the first check is reported", f"list #9 (Old thread): now followed (open, 4 comments) {ELSEWHERE}" in out)
    check("the search keeps to the issues active lately", any("updated%3A%3E%3D" in path for path in FakeGitHub.asked))
    FakeGitHub.elsewhere = {}

    # 3. Closed as not planned: a quiet check keeps it unread, status shows it, read clears it.
    FakeGitHub.issue = issue("closed", "2026-10-22T09:00:00Z", 3, ["bug"], "not_planned")
    run(pr, pr.check, False, True)
    changes = status()["issues"][0]["changes"]
    check("a quiet check keeps the close unread", changes == ["closed (not planned)", "unlabeled triage"])
    run(pr, pr.read, ISSUE)
    check("read clears it", status()["issues"][0]["changes"] == [])

    # 4. Turned off in the pane's settings: not looked up, reported or listed, its record kept; turned
    # on again, what changed meanwhile is reported.
    settings = root / "claude" / "settings.json"
    settings.parent.mkdir(parents=True, exist_ok=True)

    def pane(options: dict) -> None:
        settings.write_text(json.dumps({"pluginConfigs": {"pr-pane@inline": {"options": options}}}), encoding="utf-8")

    pane({"issues": False})
    FakeGitHub.asked.clear()
    FakeGitHub.issue = issue("open", "2026-10-23T09:00:00Z", 3, ["bug"])
    out = run(pr, pr.check, False)
    check("issues turned off are not looked up", not any("issues" in path for path in FakeGitHub.asked))
    check("nor reported", out.strip() == "No change.")
    check("nor listed", status()["issues"] == [])
    pane({"issues": True})
    out = run(pr, pr.check, False)
    check("turned on again, what changed meanwhile is reported", f"app #5 (Crash on start): reopened {ISSUE}" in out)

    # 5. Unfollowed: no longer shown; `add` follows it again.
    run(pr, pr.remove, ISSUE)
    check("an unfollowed issue is no longer shown", status()["issues"] == [])
    out = run(pr, pr.add, ISSUE, "")
    check("add follows it again", "followed again" in out and [row["url"] for row in status()["issues"]] == [ISSUE])

    # 6. Pipeline runs: so many per repo, config.json's count unless the pane sets one.
    (root / "pr-watch" / "config.json").write_text(json.dumps({"runsPerRepo": 1}), encoding="utf-8")
    pane({})
    runs = [{"repo": "api", "url": "1"}, {"repo": "api", "url": "2"}, {"repo": "web", "url": "3"}]
    check("config.json's count of runs per repo", [one["url"] for one in pr.shown_runs(runs)] == ["1", "3"])
    pane({"runsPerRepo": 2})
    check("the pane's count wins", [one["url"] for one in pr.shown_runs(runs)] == ["1", "2", "3"])

    # 7. Low power mode: every pace five times slower, on battery by default.
    battery = [False]
    pr.on_battery = lambda: battery[0]
    pane({})
    check("on mains, the usual paces", pr.cache_minutes()["running"] == 1.0)
    battery[0] = True
    check("on battery, five times slower by default", pr.cache_minutes() == {"running": 5.0, "runs": 25.0, "prs": 50.0, "lists": 75.0})
    pane({"lowPower": "off"})
    check("off, the usual paces even on battery", pr.cache_minutes()["prs"] == 10.0)
    battery[0] = False
    pane({"lowPower": "on", "minutesPrs": 4})
    check("on, slower even on mains, from the pane's own paces", pr.cache_minutes()["prs"] == 20.0)

    server.shutdown()
    print(f"{len(failures)} failed" if failures else "all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
