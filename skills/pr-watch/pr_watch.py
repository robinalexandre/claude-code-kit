"""Track pull requests until they are merged: report new comments, votes, CI results and status changes.

    pr_watch.py add URL [--note TEXT]   start tracking a PR (takes a baseline, reports nothing)
    pr_watch.py check [--peek]          what changed on every tracked PR since the last check
                                        (--peek: report without recording it as seen)
    pr_watch.py list                    tracked PRs and their status
    pr_watch.py status [--live]         the same as JSON, with what each PR waits for
                                        (--live: fetched now, with the changes; records nothing)
    pr_watch.py open URL                open a PR in the default browser
    pr_watch.py details URL             JSON: the PR's failed checks with their failed steps and errors
    pr_watch.py rerun URL CHECK         relaunch a check (Azure DevOps: re-queue; GitHub: rerun failed jobs)
    pr_watch.py approve URL             approve a PR (Azure DevOps: vote approved; GitHub: an approving review)
    pr_watch.py remove URL              stop tracking a PR

Tracked PRs live in $PR_WATCH_DIR (default ~/.claude-sync/pr-watch), one JSON file per PR, so the
config sync carries them to every computer. A merged, abandoned or closed PR is reported once, then
dropped. Supported: Azure DevOps (az login or AZURE_DEVOPS_PAT) and GitHub (GITHUB_TOKEN, gh, or
anonymous for public repos).

`check` and `status --live` also look up the open PRs waiting for the user's review (GitHub with a
token; the Azure DevOps organizations of the tracked PRs and of `azureOrgs` in config.json): a new
one is reported, and `status` lists them as `reviews` from the last check.
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
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from functools import partial
from pathlib import Path
from typing import Callable


WATCH_DIR = Path(os.environ.get("PR_WATCH_DIR", Path.home() / ".claude-sync" / "pr-watch"))
CONFIG = WATCH_DIR / "config.json"
REVIEWS = WATCH_DIR / "reviews.json"
DONE_DIR = WATCH_DIR / "done"
KEEP_DAYS = float(os.environ.get("PR_WATCH_KEEP_DAYS", "7"))
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


def _http_text(url: str, headers: dict[str, str]) -> str:
    request = urllib.request.Request(url, headers={"Accept": "text/plain", **headers})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.read().decode("utf-8-sig", errors="replace")
    except (urllib.error.HTTPError, urllib.error.URLError) as error:
        raise WatchError(f"{url.split('?')[0]}: {error}") from error


LOG_STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")
LOG_ERROR = re.compile(r"error|failed|exception|denied|not found|fatal", re.IGNORECASE)


def log_tail(text: str, count: int = 6) -> list[str]:
    """The last lines of a log that look like errors, timestamps and pipeline markers left out."""
    lines = [LOG_STAMP.sub("", line).strip() for line in text.splitlines()]
    lines = [line for line in lines if line and not line.startswith(("##[section]", "##[command]", "=="))]
    picked = [line.removeprefix("##[error]") for line in lines if LOG_ERROR.search(line)]
    return picked[-count:]


def _http_json(url: str, headers: dict[str, str], method: str = "GET", body: object = None) -> object:
    if body is not None:
        data: bytes | None = json.dumps(body).encode("utf-8")
    else:
        data = b"" if method != "GET" else None
    extra = {"Content-Type": "application/json"} if data is not None else {}
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Accept": "application/json", **extra, **headers})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as error:
        raise WatchError(f"{url.split('?')[0]}: HTTP {error.code}") from error
    except urllib.error.URLError as error:
        raise WatchError(f"{url.split('?')[0]}: {error.reason}") from error
    if not body.strip():
        return {}
    try:
        return json.loads(body)
    except json.JSONDecodeError as error:
        raise WatchError(f"{url.split('?')[0]}: not JSON (signed out?)") from error


_ADO_HEADERS: dict[str, str] = {}
_ADO_LOCK = threading.Lock()


def _ado_headers() -> dict[str, str]:
    """One token for every PR: `az account get-access-token` takes seconds per call."""
    with _ADO_LOCK:
        if not _ADO_HEADERS:
            pat = os.environ.get("AZURE_DEVOPS_PAT") or os.environ.get("AZURE_DEVOPS_EXT_PAT")
            if pat:
                _ADO_HEADERS["Authorization"] = "Basic " + base64.b64encode(f":{pat}".encode()).decode()
            else:
                token = _run("az", "account", "get-access-token", "--resource", ADO_RESOURCE,
                             "--query", "accessToken", "-o", "tsv")
                if not token:
                    raise WatchError("Azure DevOps: no AZURE_DEVOPS_PAT and `az login` has no token")
                _ADO_HEADERS["Authorization"] = f"Bearer {token}"
        return dict(_ADO_HEADERS)


class AzureDevOps:
    def __init__(self, match: re.Match[str]) -> None:
        org = match["org"] or match["org2"]
        self.base = f"https://dev.azure.com/{org}/{match['project']}/_apis"
        self.repo, self.id = match["repo"], match["id"]
        self._definitions: dict[int, str] = {}

    def headers(self) -> dict[str, str]:
        return _ado_headers()

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
            "target": pr.get("targetRefName", "").removeprefix("refs/heads/"),
            "source": pr.get("sourceRefName", "").removeprefix("refs/heads/"),
            "conflicts": pr.get("mergeStatus") == "conflicts",
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
                "build": build,
                "evaluation": evaluation["evaluationId"],
            }
        return checks

    def errors(self, check: dict) -> list[str]:
        """The failed steps of the check's build and their error messages."""
        if not check.get("build"):
            return []
        records = self.get(f"build/builds/{check['build']}/timeline").get("records") or []
        lines = []
        for record in records:
            if record.get("result") != "failed" or record.get("type") not in {"Task", "Job", "Checkpoint"}:
                continue
            messages = [issue["message"] for issue in record.get("issues") or [] if issue.get("type") == "error"]
            if record["type"] == "Task" and (record.get("log") or {}).get("url"):
                try:
                    tail = log_tail(_http_text(record["log"]["url"], self.headers()))
                except WatchError:
                    tail = []
                messages += [line for line in tail if line not in messages]
            if record["type"] == "Task" or messages:
                lines.append(f"{record['name']}: failed")
            lines += [f"  {message[:EXCERPT]}" for message in messages[:8]]
        return lines[:24]

    def rerun(self, check: dict) -> None:
        """Re-queues the build policy, as the PR's Re-queue button does."""
        if not check.get("evaluation"):
            raise WatchError("this check has no policy evaluation to re-queue")
        _http_json(f"{self.base}/policy/evaluations/{check['evaluation']}?api-version=7.1-preview.1",
                   self.headers(), method="PATCH")

    def approve(self) -> None:
        """Votes approved as the person checking (adds them as a reviewer if they are not one)."""
        _http_json(f"{self.base}/git/repositories/{self.repo}/pullrequests/{self.id}/reviewers/{self.me()}"
                   "?api-version=7.1", self.headers(), method="PUT", body={"vote": 10})

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


def ado_review_requests(org: str) -> list[dict]:
    """The organization's active PRs on which the person checking is a reviewer who has not voted."""
    headers = _ado_headers()
    me = _http_json(f"https://dev.azure.com/{org}/_apis/connectionData", headers)["authenticatedUser"]["id"]  # type: ignore[index]
    found = _http_json(f"https://dev.azure.com/{org}/_apis/git/pullrequests?searchCriteria.reviewerId={me}"
                       "&searchCriteria.status=active&$top=100&api-version=7.1", headers)["value"]  # type: ignore[index]
    rows = []
    for pr in found:
        mine = next((r for r in pr.get("reviewers", []) if r["id"] == me), None)
        if mine is None or mine.get("vote") or pr.get("isDraft") or pr["createdBy"]["id"] == me:
            continue
        project, repo = pr["repository"]["project"]["name"], pr["repository"]["name"]
        rows.append({
            "url": f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_git/{urllib.parse.quote(repo)}"
                   f"/pullrequest/{pr['pullRequestId']}",
            "repo": repo,
            "number": str(pr["pullRequestId"]),
            "title": pr["title"],
            "author": pr["createdBy"]["displayName"],
            "updated": _stamp(pr.get("creationDate", "")),
        })
    return rows


def _github_token() -> str:
    return os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or _run("gh", "auth", "token")


def github_review_requests() -> list[dict]:
    """The open, non-draft PRs whose review is requested from the person checking (none anonymously)."""
    token = _github_token()
    if not token:
        return []
    headers = {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"}
    query = urllib.parse.quote("is:pr is:open draft:false review-requested:@me")
    found = _http_json(f"https://api.github.com/search/issues?q={query}&sort=updated&per_page=50", headers)
    rows = []
    for item in found.get("items", []):  # type: ignore[union-attr]
        match = GITHUB_URL.match(item["html_url"])
        if match is None:
            continue
        rows.append({
            "url": item["html_url"],
            "repo": match["repo"],
            "number": match["id"],
            "title": item["title"],
            "author": item["user"]["login"],
            "updated": _stamp(item.get("updated_at", "")),
        })
    return rows


def _stamp(iso: str) -> str:
    """An ISO date from either host as `_now` writes them (minutes, UTC)."""
    try:
        at = datetime.fromisoformat(re.sub(r"\.\d+", "", iso).replace("Z", "+00:00"))
    except ValueError:
        return ""
    return at.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


class GitHub:
    def __init__(self, match: re.Match[str]) -> None:
        self.base = f"https://api.github.com/repos/{match['owner']}/{match['repo']}"
        self.id = match["id"]
        token = _github_token()
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
        return {"title": pr["title"], "status": status, "target": pr["base"]["ref"], "source": pr["head"]["ref"],
                "conflicts": pr.get("mergeable_state") == "dirty", "votes": votes, "comments": comments,
                "checks": self.checks(pr["head"]["sha"])}

    def checks(self, sha: str) -> dict[str, dict]:
        """Check runs (GitHub Actions and apps) and commit statuses on the PR's head commit."""
        checks = {}
        for run in self.get(f"commits/{sha}/check-runs?per_page=100")["check_runs"]:  # type: ignore[index]
            state = run["conclusion"] if run["status"] == "completed" else run["status"]
            checks[run["name"]] = {"state": GITHUB_STATES.get(state, state), "required": None,
                                   "link": run.get("html_url"), "run": run["id"]}
        for status in self.get(f"commits/{sha}/status")["statuses"]:  # type: ignore[index]
            checks[status["context"]] = {"state": GITHUB_STATES.get(status["state"], status["state"]),
                                         "required": None, "link": status.get("target_url")}
        return checks

    def errors(self, check: dict) -> list[str]:
        """The failed steps of an Actions job, then the check's failure annotations."""
        lines = []
        job = ACTIONS_JOB.search(check.get("link") or "")
        if job:
            steps = self.get(f"actions/jobs/{job['job']}").get("steps", [])  # type: ignore[union-attr]
            lines += [f"{step['name']}: failed" for step in steps if step.get("conclusion") == "failure"]
        if check.get("run"):
            for annotation in self.get(f"check-runs/{check['run']}/annotations")[:10]:  # type: ignore[index]
                if annotation.get("annotation_level") == "failure":
                    where = f"{annotation['path']}: " if annotation.get("path") else ""
                    lines.append(f"  {where}{(annotation.get('message') or '')[:EXCERPT]}")
        return lines[:20]

    def rerun(self, check: dict) -> None:
        """Re-runs the failed jobs of an Actions run, or re-requests another app's check."""
        job = ACTIONS_JOB.search(check.get("link") or "")
        if job:
            _http_json(f"{self.base}/actions/runs/{job['run']}/rerun-failed-jobs", self.post_headers(), method="POST")
        elif check.get("run"):
            _http_json(f"{self.base}/check-runs/{check['run']}/rerequest", self.post_headers(), method="POST")
        else:
            raise WatchError("a commit status is set by an outside service: rerun it there")

    def approve(self) -> None:
        """Submits an approving review with no body."""
        _http_json(f"{self.base}/pulls/{self.id}/reviews", self.post_headers(), method="POST", body={"event": "APPROVE"})

    def post_headers(self) -> dict[str, str]:
        if not self.headers:
            raise WatchError("GitHub: writing needs GITHUB_TOKEN or `gh auth login`")
        return {"X-GitHub-Api-Version": "2022-11-28", **self.headers}


ACTIONS_JOB = re.compile(r"/actions/runs/(?P<run>\d+)/job/(?P<job>\d+)")


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
            for path in sorted(WATCH_DIR.glob("*.json")) if path not in (CONFIG, REVIEWS)]


def cached_reviews() -> list[dict]:
    """The review requests found by the last check."""
    if not REVIEWS.exists():
        return []
    return json.loads(REVIEWS.read_text(encoding="utf-8")).get("reviews", [])


def fetch_review_requests(entries: list[tuple[Path, dict]]) -> tuple[list[dict], list[str]]:
    """Open PRs waiting for the user's review, newest first: (rows, errors).

    GitHub needs a token; Azure DevOps is asked per organization, those of the tracked PRs plus
    `azureOrgs` in config.json.
    """
    orgs = config("azureOrgs")
    for _, entry in entries:
        if match := ADO_URL.match(entry["url"]):
            orgs.add(match["org"] or match["org2"])
    jobs: list[Callable[[], list[dict]]] = [github_review_requests]
    jobs += [partial(ado_review_requests, org) for org in sorted(orgs)]

    def one(job: Callable[[], list[dict]]) -> tuple[list[dict], str]:
        try:
            return job(), ""
        except WatchError as error:
            return [], f"review requests: {error}"
        except (KeyError, TypeError) as error:
            return [], f"review requests: unexpected answer ({error!r})"

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, jobs))
    rows = sorted((row for found, _ in results for row in found), key=lambda row: row["updated"], reverse=True)
    return rows, [error for _, error in results if error]


def done_entries() -> list[dict]:
    """PRs merged, abandoned or closed in the last KEEP_DAYS days, newest first."""
    entries = [json.loads(path.read_text(encoding="utf-8")) for path in DONE_DIR.glob("*.json")]
    return sorted(entries, key=lambda entry: entry.get("ended", ""), reverse=True)


def prune_done() -> None:
    now = datetime.now(timezone.utc)
    for path in DONE_DIR.glob("*.json"):
        ended = json.loads(path.read_text(encoding="utf-8")).get("ended", "")
        try:
            age = now - datetime.strptime(ended, "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc)
        except ValueError:
            age = None
        if age is None or age.total_seconds() > KEEP_DAYS * 86400:
            path.unlink()


def save(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
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
    if now.get("conflicts") and not before.get("conflicts"):
        lines.append(f"{name}: merge conflicts with {now.get('target') or 'its target branch'}")
    elif before.get("conflicts") and not now.get("conflicts") and now["status"] not in FINAL:
        lines.append(f"{name}: merge conflicts resolved")
    for reviewer, vote in now["votes"].items():
        if before["votes"].get(reviewer) != vote:
            lines.append(f"{name}: {reviewer} voted {vote}")
    for reviewer, vote in before["votes"].items():
        if reviewer not in now["votes"]:
            lines.append(f"{name}: {reviewer}'s vote ({vote}) was reset or dismissed")
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


def fetch_all(entries: list[tuple[Path, dict]]) -> list[tuple[Path, dict, dict | None, str, str]]:
    """Every PR's snapshot, fetched in parallel: (path, entry, snapshot or None, me, error).

    `me` is the person checking, looked up once per host.
    """
    me: dict[str, str] = {}
    lock = threading.Lock()

    def one(item: tuple[Path, dict]) -> tuple[Path, dict, dict | None, str, str]:
        path, entry = item
        try:
            pr = provider(entry["url"])
            host = type(pr).__name__ + pr.base.split("/")[3]
            with lock:
                known = me.get(host)
            if known is None:
                known = pr.me()
                with lock:
                    me[host] = known
            return path, entry, pr.snapshot(), known, ""
        except WatchError as error:
            return path, entry, None, "", str(error)

    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(one, entries))


def check(peek: bool) -> None:
    """With `peek`, report without recording: the changes are reported again at the next check.

    Comments by the person checking are left out.
    """
    ignore, bots, report, errors = config("ignoreAuthors"), config("bots"), [], []
    entries = load_entries()
    for path, entry, now, me, error in fetch_all(entries):
        if now is None:
            errors.append(f"{entry['url']}: {error}")
            continue
        report += changes(entry, now, ignore | {me} - {""}, bots)
        if peek:
            continue
        if now["status"] in FINAL:
            save(DONE_DIR / path.name, {**entry, "checked": _now(), "ended": _now(), "seen": now})
            path.unlink()
            report.append(f"{label(entry)}: {now['status']}, no longer tracked")
        else:
            save(path, {**entry, "checked": _now(), "seen": now})
    reviews, review_errors = fetch_review_requests(entries)
    known = {row["url"] for row in cached_reviews()}
    report += [f"{row['repo']} #{row['number']} ({row['title']}): {row['author']} asks for your review"
               for row in reviews if row["url"] not in known]
    errors += review_errors
    if not peek:
        # Saved even when a host failed: its requests are reported again once it answers.
        save(REVIEWS, {"checked": _now(), "reviews": reviews})
        prune_done()
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


MAIN_BRANCHES = {"main", "master", "develop", "development", "trunk"}


def waiting_for(seen: dict) -> str:
    """What the PR waits for next, from what was seen."""
    if seen["status"] in FINAL:
        return seen["status"]
    checks = seen.get("checks", {})
    votes = set(seen["votes"].values())
    target = seen.get("target", "")
    ci = ci_summary(checks)
    if seen.get("conflicts"):
        return "a conflict fix"
    if any(c["state"] == "expired" and c["required"] is not False for c in checks.values()):
        return "CI to be queued again"
    if ci.startswith("CI failed"):
        return "a CI fix"
    if votes & {"rejected", "waiting for author", "changes requested"}:
        return "changes from us"
    if ci == "no CI" and target and target not in MAIN_BRANCHES:
        return f"the PR into {target} to merge first"
    if ci.startswith("CI running"):
        return "CI"
    if not votes & {"approved", "approved with suggestions"}:
        return "a review"
    return "the merge"


def status(live: bool) -> None:
    """JSON for a pane or a script; `live` fetches every PR now but records nothing."""
    entries = load_entries()
    fetched = fetch_all(entries) if live else [(p, e, None, "", "") for p, e in entries]
    reviews, errors = fetch_review_requests(entries) if live else (cached_reviews(), [])
    ignore, bots, prs = config("ignoreAuthors"), config("bots"), []
    for _, entry, now, me, error in fetched:
        if error:
            errors.append(f"{entry['url']}: {error}")
        seen = now or entry["seen"]
        match = ADO_URL.match(entry["url"]) or GITHUB_URL.match(entry["url"])
        prefix = f"{label(entry)}: "
        news = [line.removeprefix(prefix) for line in changes(entry, now, ignore | {me} - {""}, bots)] if now else []
        prs.append({
            "url": entry["url"],
            "repo": match["repo"] if match else "",
            "number": match["id"] if match else "",
            "title": seen["title"],
            "status": seen["status"],
            "target": seen.get("target", ""),
            "source": seen.get("source", ""),
            "conflicts": bool(seen.get("conflicts")),
            "ci": ci_summary(seen.get("checks", {})),
            "checks": sorted(({"name": name, **check} for name, check in seen.get("checks", {}).items()),
                             key=lambda c: (c["required"] is False, c["name"].lower())),
            "votes": seen["votes"],
            "waiting": waiting_for(seen),
            "note": entry.get("note", ""),
            "changes": news,
            "checked": _now() if now else entry.get("checked", ""),
        })
    recent = []
    for entry in done_entries():
        match = ADO_URL.match(entry["url"]) or GITHUB_URL.match(entry["url"])
        recent.append({
            "url": entry["url"],
            "repo": match["repo"] if match else "",
            "number": match["id"] if match else "",
            "title": entry["seen"]["title"],
            "status": entry["seen"]["status"],
            "target": entry["seen"].get("target", ""),
            "ended": entry.get("ended", ""),
        })
    print(json.dumps({"live": live, "prs": merge_order(prs), "reviews": reviews, "recent": recent, "errors": errors},
                     ensure_ascii=False))


def merge_order(prs: list[dict]) -> list[dict]:
    """Grouped by repo; in a repo, each PR before the PRs stacked on it (whose target is its branch).

    Sets `after` to the number of the tracked PR a PR is stacked on.
    """
    ordered: list[dict] = []
    by_repo: dict[str, list[dict]] = {}
    for pr in prs:
        by_repo.setdefault(pr["repo"], []).append(pr)
    for repo in sorted(by_repo, key=str.lower):
        group = by_repo[repo]
        by_source = {pr["source"]: pr for pr in group if pr["source"]}
        stacked_on: dict[str, list[dict]] = {}
        for pr in group:
            parent = by_source.get(pr["target"])
            pr["after"] = parent["number"] if parent is not None and parent is not pr else ""
            if pr["after"] and pr["waiting"].startswith("the PR into "):
                pr["waiting"] = f"#{pr['after']} to merge first"
            stacked_on.setdefault(pr["after"], []).append(pr)

        def walk(number: str) -> None:
            for pr in sorted(stacked_on.get(number, []), key=lambda p: int(p["number"] or 0)):
                ordered.append(pr)
                walk(pr["number"])

        walk("")
        placed = {id(pr) for pr in ordered}
        ordered += [pr for pr in group if id(pr) not in placed]
    return ordered


FAILED = {"failed", "broken", "expired"}


def details(url: str) -> None:
    """JSON: each failed check of the PR, fetched now, with its failed steps and errors."""
    pr = provider(normalize(url))
    checks = pr.snapshot()["checks"]
    failed = []
    for name, check in checks.items():
        if check["state"] not in FAILED:
            continue
        try:
            errors = pr.errors(check) if check["state"] != "expired" else ["expired: queue it again"]
        except WatchError as error:
            errors = [f"could not read the errors: {error}"]
        if not errors:
            errors = ["no step details kept: see the build log"]
        failed.append({"name": name, "state": check["state"], "link": check["link"], "errors": errors})
    print(json.dumps({"url": normalize(url), "checks": failed}, ensure_ascii=False))


def rerun(url: str, name: str) -> None:
    pr = provider(normalize(url))
    check = pr.snapshot()["checks"].get(name)
    if check is None:
        raise WatchError(f"no check named {name!r} on {url}")
    pr.rerun(check)
    print(f"relaunched {name}")


def approve(url: str) -> None:
    pr = provider(normalize(url))
    pr.approve()
    reviews = [row for row in cached_reviews() if row["url"] != normalize(url)]
    if REVIEWS.exists():
        save(REVIEWS, {**json.loads(REVIEWS.read_text(encoding="utf-8")), "reviews": reviews})
    print(f"approved {normalize(url)}")


def open_(url: str) -> None:
    if not (ADO_URL.match(url) or GITHUB_URL.match(url)):
        raise WatchError(f"unsupported PR URL (Azure DevOps or GitHub): {url}")
    if not webbrowser.open(url):
        raise WatchError(f"no browser could open {url}")


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
        elif command == "status":
            status(live="--live" in args)
        elif command == "open" and args:
            open_(args[0])
        elif command == "details" and args:
            details(args[0])
        elif command == "rerun" and len(args) >= 2:
            rerun(args[0], " ".join(args[1:]))
        elif command == "approve" and args:
            approve(args[0])
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
