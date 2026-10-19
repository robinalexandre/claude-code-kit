"""Track pull requests until they are merged: report new comments, votes, CI results and status changes.

    pr_watch.py add URL [--note TEXT]   start tracking a PR (takes a baseline, reports nothing)
    pr_watch.py check [--peek]          what changed on every tracked PR since the last check
                                        (--peek: report without recording it as seen)
    pr_watch.py list                    tracked PRs and their status
    pr_watch.py remove URL              stop tracking a PR

Tracked PRs live in $PR_WATCH_DIR (default ~/.claude-sync/pr-watch), one JSON file per PR, so the
config sync carries them to every computer. A merged, abandoned or closed PR is reported once, then
dropped. Supported: Azure DevOps (az login or AZURE_DEVOPS_PAT) and GitHub (GITHUB_TOKEN, gh, or
anonymous for public repos).
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

from datetime import datetime, timezone
from pathlib import Path


WATCH_DIR = Path(os.environ.get("PR_WATCH_DIR", Path.home() / ".claude-sync" / "pr-watch"))
CONFIG = WATCH_DIR / "config.json"
ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
FINAL = {"merged", "completed", "abandoned", "closed"}
EXCERPT = 400

ADO_URL = re.compile(
    r"https://(?:dev\.azure\.com/(?P<org>[^/]+)|(?P<org2>[^./]+)\.visualstudio\.com)"
    r"/(?P<project>[^/]+)/_git/(?P<repo>[^/]+)/pullrequest/(?P<id>\d+)"
)
GITHUB_URL = re.compile(r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<id>\d+)")


class WatchError(Exception):
    pass


def _run(*args: str) -> str:
    exe = shutil.which(args[0])
    if exe is None:
        return ""
    result = subprocess.run([exe, *args[1:]], capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def _http_json(url: str, headers: dict[str, str]) -> object:
    request = urllib.request.Request(url, headers={"Accept": "application/json", **headers})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise WatchError(f"{url.split('?')[0]}: HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise WatchError(f"{url.split('?')[0]}: {error.reason}") from error
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise WatchError(f"{url.split('?')[0]}: not JSON (signed out?)") from error


class AzureDevOps:
    def __init__(self, match: re.Match[str]) -> None:
        org = match["org"] or match["org2"]
        self.base = f"https://dev.azure.com/{org}/{match['project']}/_apis"
        self.repo, self.id = match["repo"], match["id"]
        self._headers: dict[str, str] | None = None
        self._definitions: dict[int, str] = {}

    def headers(self) -> dict[str, str]:
        if self._headers is None:
            pat = os.environ.get("AZURE_DEVOPS_PAT") or os.environ.get("AZURE_DEVOPS_EXT_PAT")
            if pat:
                self._headers = {"Authorization": "Basic " + base64.b64encode(f":{pat}".encode()).decode()}
            else:
                token = _run("az", "account", "get-access-token", "--resource", ADO_RESOURCE,
                             "--query", "accessToken", "-o", "tsv")
                if not token:
                    raise WatchError("Azure DevOps: no AZURE_DEVOPS_PAT and `az login` has no token")
                self._headers = {"Authorization": f"Bearer {token}"}
        return self._headers

    def get(self, path: str) -> dict:
        separator = "&" if "?" in path else "?"
        return _http_json(f"{self.base}/{path}{separator}api-version=7.1", self.headers())  # type: ignore[return-value]

    def me(self) -> str:
        org_api = self.base.rsplit("/", 2)[0] + "/_apis/connectionData"
        return _http_json(org_api, self.headers())["authenticatedUser"]["id"]  # type: ignore[index]

    def snapshot(self) -> dict:
        pr = self.get(f"git/repositories/{self.repo}/pullrequests/{self.id}")
        threads = self.get(f"git/repositories/{self.repo}/pullrequests/{self.id}/threads")["value"]
        comments = {}
        for thread in threads:
            if thread.get("isDeleted") or thread.get("properties", {}).get("CodeReviewThreadType"):
                continue
            for comment in thread.get("comments", []):
                if comment.get("commentType") == "system" or comment.get("isDeleted"):
                    continue
                comments[f"{thread['id']}/{comment['id']}"] = {
                    "author": comment["author"]["displayName"],
                    "author_id": comment["author"]["id"],
                    "text": (comment.get("content") or "")[:EXCERPT],
                    "file": (thread.get("threadContext") or {}).get("filePath"),
                }
        return {
            "title": pr["title"],
            "status": pr["status"],
            "votes": {r["displayName"]: _ado_vote(r["vote"]) for r in pr.get("reviewers", []) if r["vote"]},
            "comments": comments,
            "checks": self.checks(pr["repository"]["project"]["id"]),
        }

    def checks(self, project_id: str) -> dict[str, dict]:
        """The PR's build and status policies: the CI the target branch requires."""
        artifact = f"vstfs:///CodeReview/CodeReviewId/{project_id}/{self.id}"
        evaluations = _http_json(
            f"{self.base}/policy/evaluations?artifactId={artifact}&api-version=7.1-preview.1", self.headers()
        )["value"]  # type: ignore[index]
        checks = {}
        for evaluation in evaluations:
            config = evaluation["configuration"]
            kind = config["type"]["displayName"]
            if kind not in {"Build", "Status"} or evaluation["status"] == "notApplicable":
                continue
            settings, context = config["settings"], evaluation.get("context") or {}
            name = (settings.get("displayName")
                    or self._definition_name(settings.get("buildDefinitionId"))
                    or "/".join(filter(None, (settings.get("statusGenre"), settings.get("statusName"))))
                    or kind)
            state = {"approved": "passed", "rejected": "failed"}.get(evaluation["status"], evaluation["status"])
            if context.get("isExpired"):
                state = "expired"
            build = context.get("buildId")
            checks[name] = {
                "state": state,
                "required": config["isBlocking"],
                "link": f"{self.base.removesuffix('/_apis')}/_build/results?buildId={build}" if build else None,
            }
        return checks

    def _definition_name(self, definition_id: int | None) -> str:
        if definition_id is None:
            return ""
        if definition_id not in self._definitions:
            self._definitions[definition_id] = self.get(f"build/definitions/{definition_id}")["name"]
        return self._definitions[definition_id]


def _ado_vote(vote: int) -> str:
    return {10: "approved", 5: "approved with suggestions", -5: "waiting for author", -10: "rejected"}.get(
        vote, str(vote)
    )


class GitHub:
    def __init__(self, match: re.Match[str]) -> None:
        self.base = f"https://api.github.com/repos/{match['owner']}/{match['repo']}"
        self.id = match["id"]
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or _run("gh", "auth", "token")
        self.headers = {"Authorization": f"Bearer {token}"} if token else {}

    def get(self, path: str) -> object:
        return _http_json(f"{self.base}/{path}", {"X-GitHub-Api-Version": "2022-11-28", **self.headers})

    def me(self) -> str:
        if not self.headers:
            return ""
        return _http_json("https://api.github.com/user", self.headers)["login"]  # type: ignore[index]

    def snapshot(self) -> dict:
        pr = self.get(f"pulls/{self.id}")
        assert isinstance(pr, dict)
        comments = {}
        for kind, path in (("issue", f"issues/{self.id}/comments?per_page=100"),
                           ("review", f"pulls/{self.id}/comments?per_page=100"),
                           ("summary", f"pulls/{self.id}/reviews?per_page=100")):
            for item in self.get(path):  # type: ignore[union-attr]
                if kind == "summary" and not item.get("body"):
                    continue
                comments[f"{kind}/{item['id']}"] = {
                    "author": item["user"]["login"],
                    "author_id": item["user"]["login"],
                    "text": (item.get("body") or "")[:EXCERPT],
                    "file": item.get("path"),
                }
        reviews = self.get(f"pulls/{self.id}/reviews?per_page=100")
        votes = {r["user"]["login"]: r["state"].lower().replace("_", " ") for r in reviews  # type: ignore[union-attr]
                 if r["state"] in {"APPROVED", "CHANGES_REQUESTED"}}
        status = "merged" if pr.get("merged_at") else pr["state"]
        return {"title": pr["title"], "status": status, "votes": votes, "comments": comments,
                "checks": self.checks(pr["head"]["sha"])}

    def checks(self, sha: str) -> dict[str, dict]:
        """Check runs (GitHub Actions and apps) and commit statuses on the PR's head commit."""
        checks = {}
        for run in self.get(f"commits/{sha}/check-runs?per_page=100")["check_runs"]:  # type: ignore[index]
            state = run["conclusion"] if run["status"] == "completed" else run["status"]
            checks[run["name"]] = {"state": GITHUB_STATES.get(state, state), "required": None,
                                   "link": run.get("html_url")}
        for status in self.get(f"commits/{sha}/status")["statuses"]:  # type: ignore[index]
            checks[status["context"]] = {"state": GITHUB_STATES.get(status["state"], status["state"]),
                                         "required": None, "link": status.get("target_url")}
        return checks


GITHUB_STATES = {"success": "passed", "failure": "failed", "error": "failed", "timed_out": "failed",
                 "cancelled": "failed", "action_required": "failed", "pending": "running",
                 "in_progress": "running", "neutral": "skipped"}


def provider(url: str) -> AzureDevOps | GitHub:
    if match := ADO_URL.match(url):
        return AzureDevOps(match)
    if match := GITHUB_URL.match(url):
        return GitHub(match)
    raise WatchError(f"unsupported PR URL (Azure DevOps or GitHub): {url}")


def normalize(url: str) -> str:
    return url.strip().split("?")[0].split("#")[0].rstrip("/")


def entry_path(url: str) -> Path:
    match = ADO_URL.match(url) or GITHUB_URL.match(url)
    repo = match["repo"] if match else "pr"
    number = match["id"] if match else "0"
    digest = hashlib.sha1(url.encode()).hexdigest()[:8]
    return WATCH_DIR / f"{re.sub(r'[^A-Za-z0-9_.-]', '-', repo)}-{number}-{digest}.json"


def load_entries() -> list[tuple[Path, dict]]:
    return [(path, json.loads(path.read_text(encoding="utf-8")))
            for path in sorted(WATCH_DIR.glob("*.json")) if path != CONFIG]


def save(path: Path, entry: dict) -> None:
    WATCH_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entry, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")


def config(key: str) -> set[str]:
    """`ignoreAuthors`: never reported; `bots`: reported, marked (bot), for the reader to triage."""
    if not CONFIG.exists():
        return set()
    return set(json.loads(CONFIG.read_text(encoding="utf-8")).get(key, []))


def ci_summary(checks: dict[str, dict]) -> str:
    """Driven by the required checks (all of them when the provider doesn't say which are)."""
    required = {name: c for name, c in checks.items() if c["required"] is not False}
    states = {check["state"] for check in required.values()}
    optional_failed = sorted(name for name, c in checks.items()
                             if name not in required and c["state"] in {"failed", "broken", "expired"})
    suffix = f" (optional failed: {', '.join(optional_failed)})" if optional_failed else ""
    if not checks:
        return "no CI"
    if states & {"failed", "broken", "expired"}:
        return "CI failed" + suffix
    if states - {"passed", "skipped"}:
        return "CI running" + suffix
    return "CI green" + suffix


def label(entry: dict) -> str:
    match = ADO_URL.match(entry["url"]) or GITHUB_URL.match(entry["url"])
    where = f"{match['repo']} #{match['id']}" if match else entry["url"]
    title = entry["seen"]["title"]
    return f"{where} ({title[:57] + '...' if len(title) > 60 else title})"


def changes(entry: dict, now: dict, ignore: set[str], bots: set[str]) -> list[str]:
    before, name, lines = entry["seen"], label(entry), []
    if now["status"] != before["status"]:
        lines.append(f"{name}: {before['status']} -> {now['status']}")
    for reviewer, vote in now["votes"].items():
        if before["votes"].get(reviewer) != vote:
            lines.append(f"{name}: {reviewer} voted {vote}")
    for key, comment in now["comments"].items():
        authors = {comment["author"], comment["author_id"]}
        if key in before["comments"] or authors & ignore:
            continue
        where = f" on {comment['file']}" if comment["file"] else ""
        text = " ".join(comment["text"].split())
        bot = " (bot)" if authors & bots else ""
        lines.append(f"{name}: new comment by {comment['author']}{bot}{where}: {text}")
    if "checks" in before:
        for check, now_check in now["checks"].items():
            old = before["checks"].get(check, {}).get("state")
            if old != now_check["state"]:
                link = f" {now_check['link']}" if now_check["state"] != "passed" and now_check["link"] else ""
                lines.append(f"{name}: {check} {old or 'started'} -> {now_check['state']}{link}")
        summary = ci_summary(now["checks"])
        if summary != ci_summary(before["checks"]) and summary.startswith(("CI green", "CI failed")):
            lines.append(f"{name}: {summary}")
    return lines


def add(url: str, note: str) -> None:
    url = normalize(url)
    path = entry_path(url)
    if path.exists():
        print(f"already tracked: {url}")
        return
    seen = provider(url).snapshot()
    if seen["status"] in FINAL:
        print(f"not tracked, already {seen['status']}: {label({'url': url, 'seen': seen})}")
        return
    save(path, {"url": url, "note": note, "added": _now(), "checked": _now(), "seen": seen})
    print(f"tracking {label({'url': url, 'seen': seen})}: {seen['status']}, {ci_summary(seen['checks'])}")


def check(peek: bool) -> None:
    """With `peek`, report without recording: the changes are reported again at the next check.

    Comments by the person checking are left out, looked up once per host.
    """
    ignore, bots, report, errors, me = config("ignoreAuthors"), config("bots"), [], [], {}
    for path, entry in load_entries():
        try:
            pr = provider(entry["url"])
            host = type(pr).__name__ + pr.base.split("/")[3]
            if host not in me:
                me[host] = pr.me()
            now = pr.snapshot()
        except WatchError as error:
            errors.append(f"{entry['url']}: {error}")
            continue
        report += changes(entry, now, ignore | {me[host]} - {""}, bots)
        if peek:
            continue
        if now["status"] in FINAL:
            path.unlink()
            report.append(f"{label(entry)}: {now['status']}, no longer tracked")
        else:
            save(path, {**entry, "checked": _now(), "seen": now})
    print("\n".join(report) if report else "No change.")
    if errors:
        print("Could not check:\n" + "\n".join(errors), file=sys.stderr)


def list_() -> None:
    entries = load_entries()
    if not entries:
        print("No PR tracked.")
    for _, entry in entries:
        note = f" - {entry['note']}" if entry.get("note") else ""
        ci = ci_summary(entry["seen"].get("checks", {}))
        print(f"{entry['seen']['status']}\t{ci}\t{label(entry)}\t{entry['url']}{note}")


def remove(url: str) -> None:
    path = entry_path(normalize(url))
    if not path.exists():
        raise WatchError(f"not tracked: {url}")
    path.unlink()
    print(f"stopped tracking {normalize(url)}")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "add" and args:
            note = args[args.index("--note") + 1] if "--note" in args[1:-1] else ""
            add(args[0], note)
        elif command == "check":
            check(peek="--peek" in args)
        elif command == "list":
            list_()
        elif command == "remove" and args:
            remove(args[0])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except WatchError as error:
        print(f"pr-watch: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
