"""Track pull requests until they are merged: report new comments, votes, CI results and status changes.

    pr_watch.py add URL [--note TEXT]   start tracking a PR (takes a baseline, reports nothing), or follow
                                        an issue removed before again
    pr_watch.py check [--peek|--quiet]  what changed on every tracked PR since the last check
                                        (--peek: report without recording it as seen; --quiet:
                                        record it, print nothing, keep it on each PR as unread)
    pr_watch.py read URL                clear a PR's or a followed issue's unread changes
    pr_watch.py list                    tracked PRs and their status
    pr_watch.py status [--auto|--live]  the same as JSON, with what each PR waits for, from the records
                                        and the shared snapshot (below); each PR's `changes` start with
                                        its unread ones
                                        (--auto: each part of a host's share older than its
                                        `cacheMinutes` is fetched again and shared; --live: everything
                                        on every host this computer
                                        reaches, fetched now and shared. Both record only the user's PRs
                                        they start tracking: the PRs' changes stay for `check`)
    pr_watch.py open URL                open a PR or a build in the default browser
    pr_watch.py details URL             JSON: the PR's failed checks with their failed steps and errors,
                                        or a build's steps, every one with its job and state, those
                                        with issues with their error lines (a build URL)
    pr_watch.py rerun URL CHECK         relaunch a check (Azure DevOps: re-queue; GitHub: rerun failed jobs)
    pr_watch.py rerun BUILD_URL         launch the pipeline run again (Azure DevOps: a new run of the same
                                        pipeline, branch and parameters; GitHub: re-run the workflow run)
    pr_watch.py approve URL             approve a PR (Azure DevOps: vote approved; GitHub: an approving review)
                                        and track it as reviewed until it is merged
    pr_watch.py merge URL               merge a PR (GitHub: squash if the repo allows it; Azure DevOps: complete)
    pr_watch.py remove URL...           stop tracking a PR (and never track it again on its own), or stop
                                        following an issue; several at once
    pr_watch.py park URL [--note WHY]   keep tracking a PR without reporting its changes
    pr_watch.py unpark URL              report them again
    pr_watch.py ack URL [--until DATE] [--note TEXT]
                                        acknowledge a PR's or a run's current alert: not red any more
                                        until it changes or DATE (YYYY-MM-DD) passes
    pr_watch.py ack-all                 the same for several at once, read from stdin as JSON:
                                        [{"url": URL, "alert": {...} or absent}], `alert` as ack's --alert
    pr_watch.py unack URL               undo it

Tracked PRs live in $PR_WATCH_DIR (default ~/.claude-sync/pr-watch), one JSON file per PR, so the
config sync carries them to every computer. A merged, abandoned or closed PR is reported once, then
dropped. Supported: Azure DevOps (az login or AZURE_DEVOPS_PAT) and GitHub (GITHUB_TOKEN, gh, or
anonymous for public repos).

`check` and `status --live` also look up the open PRs waiting for the user's review (GitHub with a
token; the Azure DevOps organizations of the tracked PRs and of `azureOrgs` in config.json): a new
one is reported, and `status` lists them as `reviews` from the last check.

They also start tracking, with no `add`, the user's own open PRs (`autoTrack` in config.json, all
by default): those they opened, those assigned to them (GitHub), and those they approved as a
reviewer (tracked as reviewed). Same places as the review requests. A PR the user removed is not
tracked again on its own (dismissed.txt).

They also look up the user's pipeline runs: those they launched by hand, and the CI their pushes
started on a branch with no open PR (Azure DevOps: builds requested by them in the projects of the
tracked and recent PRs and of `azureProjects` in config.json; GitHub: in the repos of the tracked and
recent PRs, those they pushed to lately, and `githubRepos`): running ones and those ended in the last
PR_WATCH_BUILD_HOURS (default 24) hours. `check` reports a
run that ended since the last check, and `status` lists them as `builds`.

They also follow the user's GitHub issues (with a token): those involving them in any repo (opened,
commented on, mentioned or assigned in) and active in the last `issueDays` days (30 by default), and
those they subscribed to in their own and their organizations' repos; the open ones
and those closed in the last PR_WATCH_KEEP_DAYS days. `check` reports what changed on each since the user last saw it (new
comments by others, closed or reopened, labels), and `status` lists them as `issues`, each with its
`changes` (issues.json keeps what was seen).

What is looked up, reported and listed follows the PR pane's settings (the Configuration pane,
pr-pane, kept in Claude Code's settings.json), else the same keys in config.json: `openPrs`,
`parked` (the tracked PRs, open or parked), `recent` (the merged and closed ones), `reviews`,
`runsPerRepo` (0 to 20 pipeline runs per repo, 20 by default), `issues` and `issueDays`. What is
turned off is neither fetched nor reported, and its records stay as they were.

Shared snapshot: what `status --auto` or `--live` fetched is shared through the config sync's GitHub
repo, on its own branch (`pr-cache`, one commit replaced each time, so it never grows), one section per
host (`github`, `ado`) with when and by which computer. Every `status` first asks for it with one
conditional request (a 304 costs nothing against the rate limit), so a computer reads what another one
fetched instead of asking the hosts again. Each part of a section is fetched again once it is older than
its `cacheMinutes` in config.json (`{"running": 1, "runs": 5, "prs": 10, "lists": 15}` by default: the
runs in progress and the PRs whose CI runs, alone; a look for new runs; every PR; the review requests,
new PRs of the user and followed issues), and only by a computer that reaches the host (one that did
not is left alone for 30 minutes).
PR_WATCH_SHARED=off (or `"sharedCache": false` in config.json) keeps everything on this computer;
PR_WATCH_SHARED=owner/repo shares through another repo.
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
import time
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
BUILDS = WATCH_DIR / "builds.json"
ISSUES = WATCH_DIR / "issues.json"
ACKS = WATCH_DIR / "acks.json"
STEPS_DIR = WATCH_DIR / "steps"
# Not a .json file: older copies of this script read every .json file here as a tracked PR.
DISMISSED = WATCH_DIR / "dismissed.txt"
DONE_DIR = WATCH_DIR / "done"
KEEP_DAYS = float(os.environ.get("PR_WATCH_KEEP_DAYS", "7"))
BUILD_HOURS = float(os.environ.get("PR_WATCH_BUILD_HOURS", "24"))
ISSUE_DAYS = 30
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "pr-watch"
SHARED_LOCAL = CACHE_DIR / "shared.json"
SHARED_BRANCH = "pr-cache"
SHARED_PATH = "pr-watch/snapshot.json"
GITHUB_API = os.environ.get("PR_WATCH_GITHUB_API", "https://api.github.com")
HOSTS = ("github", "ado")
# How old each part of a host's share may get on `status --auto`: the runs and the PRs' CI in
# progress, the look for new runs, every tracked PR, then the lists (review requests, the user's new
# PRs, followed issues).
CACHE_MINUTES = {"running": 1.0, "runs": 5.0, "prs": 10.0, "lists": 15.0}
KINDS = ("runs", "prs", "lists")
UNREACHABLE_MINUTES = 30
PUSH_DENIED_HOURS = 6
ADO_RESOURCE = "499b84ac-1321-427f-aa17-267ca6975798"
FINAL = {"merged", "completed", "abandoned", "closed"}
EXCERPT = 400
DESCRIPTION = 1500

ADO_URL = re.compile(
    r"https://(?:dev\.azure\.com/(?P<org>[^/]+)|(?P<org2>[^./]+)\.visualstudio\.com)"
    r"/(?P<project>[^/]+)/_git/(?P<repo>[^/]+)/pullrequest/(?P<id>\d+)"
)
GITHUB_URL = re.compile(r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<id>\d+)")
GITHUB_ISSUE_URL = re.compile(r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/issues/(?P<id>\d+)")
ADO_BUILD_URL = re.compile(
    r"https://dev\.azure\.com/(?P<org>[^/]+)/(?P<project>[^/]+)/_build/results\?buildId=(?P<id>\d+)"
)
GITHUB_RUN_URL = re.compile(r"https://github\.com/(?P<owner>[^/]+)/(?P<repo>[^/]+)/actions/runs/(?P<id>\d+)")


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


ETAGS_FILE = CACHE_DIR / "etags.json"
ETAGS_KEPT = 500
ETAG_BODY_MAX = 2 * 1024 * 1024
_ETAGS: dict[str, dict] = {}
_ETAGS_LOCK = threading.Lock()
_ETAGS_READ: list[bool] = []


def _etag_of(url: str) -> dict | None:
    """The GitHub answer last read at `url`, with its ETag. Asked again with If-None-Match, an
    unchanged one comes back as a 304: no body to send, and not counted against the rate limit."""
    with _ETAGS_LOCK:
        if not _ETAGS_READ:
            _ETAGS_READ.append(True)
            try:
                _ETAGS.update(json.loads(ETAGS_FILE.read_text(encoding="utf-8")))
            except (OSError, ValueError):
                pass
        return _ETAGS.get(url)


def _keep_etag(url: str, etag: str, body: str) -> None:
    with _ETAGS_LOCK:
        _ETAGS[url] = {"etag": etag, "body": body, "used": time.time()}


def save_etags() -> None:
    """The answers used most lately, at most ETAGS_KEPT, for the next run."""
    with _ETAGS_LOCK:
        if not _ETAGS_READ:
            return
        kept = dict(sorted(_ETAGS.items(), key=lambda item: item[1].get("used", 0), reverse=True)[:ETAGS_KEPT])
    try:
        save(ETAGS_FILE, kept)
    except OSError:
        pass


def _http_json(url: str, headers: dict[str, str], method: str = "GET", body: object = None) -> object:
    if body is not None:
        data: bytes | None = json.dumps(body).encode("utf-8")
    else:
        data = b"" if method != "GET" else None
    extra = {"Content-Type": "application/json"} if data is not None else {}
    cached = _etag_of(url) if method == "GET" and url.startswith("https://api.github.com/") else None
    if cached is not None:
        extra["If-None-Match"] = cached["etag"]
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Accept": "application/json", **extra, **headers})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read().decode("utf-8")
            etag = response.headers.get("ETag", "")
        if etag and method == "GET" and url.startswith("https://api.github.com/") and len(body) <= ETAG_BODY_MAX:
            _keep_etag(url, etag, body)
    except urllib.error.HTTPError as error:
        if error.code != 304 or cached is None:
            raise WatchError(f"{url.split('?')[0]}: HTTP {error.code}") from error
        body = cached["body"]
        _keep_etag(url, cached["etag"], body)
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
        threads = self.get(f"git/repositories/{self.repo}/pullrequests/{self.id}/threads").get("value") or []
        # Azure DevOps keeps no update date on the PR: its system threads record each push, vote and
        # reviewer change, so the newest thread is its last activity.
        updated = max(filter(None, (_stamp(stamp or "") for stamp in (
            pr.get("creationDate"), pr.get("closedDate"), *(thread.get("lastUpdatedDate") for thread in threads)))),
            default="")
        comments = {}
        for thread in threads:
            if thread.get("isDeleted") or (thread.get("properties") or {}).get("CodeReviewThreadType"):
                continue
            for comment in thread.get("comments") or []:
                if comment.get("commentType") == "system" or comment.get("isDeleted"):
                    continue
                author = comment.get("author") or {}
                comments[f"{thread['id']}/{comment['id']}"] = {
                    "author": author.get("displayName") or "someone",
                    "author_id": author.get("id") or "",
                    "text": (comment.get("content") or "")[:EXCERPT],
                    "file": (thread.get("threadContext") or {}).get("filePath"),
                }
        return {
            "title": pr["title"],
            "description": (pr.get("description") or "")[:DESCRIPTION],
            "status": pr["status"],
            "target": (pr.get("targetRefName") or "").removeprefix("refs/heads/"),
            "source": (pr.get("sourceRefName") or "").removeprefix("refs/heads/"),
            "conflicts": pr.get("mergeStatus") == "conflicts",
            "votes": {r.get("displayName") or "someone": _ado_vote(r["vote"])
                      for r in pr.get("reviewers") or [] if r.get("vote")},
            "comments": comments,
            "checks": self.checks(pr["repository"]["project"]["id"]),
            "updated": updated,
        }

    def checks(self, project_id: str) -> dict[str, dict]:
        """The PR's build and status policies: the CI the target branch requires."""
        artifact = f"vstfs:///CodeReview/CodeReviewId/{project_id}/{self.id}"
        evaluations = _http_json(
            f"{self.base}/policy/evaluations?artifactId={artifact}&api-version=7.1-preview.1", self.headers()
        ).get("value") or []  # type: ignore[union-attr]
        checks = {}
        for evaluation in evaluations:
            config = evaluation.get("configuration") or {}
            kind = (config.get("type") or {}).get("displayName")
            if kind not in {"Build", "Status"} or evaluation["status"] == "notApplicable":
                continue
            settings, context = config.get("settings") or {}, evaluation.get("context") or {}
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
                "required": config.get("isBlocking", True),
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

    def merge(self) -> None:
        """Completes the PR with the project's default options, as its Complete button does."""
        pr = self.get(f"git/repositories/{self.repo}/pullrequests/{self.id}")
        commit = (pr.get("lastMergeSourceCommit") or {}).get("commitId")
        if not commit:
            raise WatchError("the PR has no merge candidate yet")
        _http_json(f"{self.base}/git/repositories/{self.repo}/pullrequests/{self.id}?api-version=7.1", self.headers(),
                   method="PATCH", body={"status": "completed", "lastMergeSourceCommit": {"commitId": commit}})

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


_ADO_ME: dict[str, str] = {}


def _ado_me(org: str) -> str:
    """The id of the person checking in the organization, looked up once per process."""
    with _ADO_LOCK:
        known = _ADO_ME.get(org)
    if known is None:
        known = _http_json(f"https://dev.azure.com/{org}/_apis/connectionData", _ado_headers())["authenticatedUser"]["id"]  # type: ignore[index]
        with _ADO_LOCK:
            _ADO_ME[org] = known
    return known


def ado_review_requests(org: str) -> list[dict]:
    """The organization's active PRs on which the person checking is a reviewer who has not voted."""
    headers = _ado_headers()
    me = _ado_me(org)
    found = _http_json(f"https://dev.azure.com/{org}/_apis/git/pullrequests?searchCriteria.reviewerId={me}"
                       "&searchCriteria.status=active&$top=100&api-version=7.1", headers)["value"]  # type: ignore[index]
    rows = []
    for pr in found:
        mine = next((r for r in pr.get("reviewers") or [] if r.get("id") == me), None)
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


_GITHUB_TOKEN: list[str] = []


def _github_token() -> str:
    """Looked up once per run: `gh auth token` is a process to start each time."""
    with _ADO_LOCK:
        if not _GITHUB_TOKEN:
            _GITHUB_TOKEN.append(os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN") or _run("gh", "auth", "token"))
        return _GITHUB_TOKEN[0]


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


def ado_my_prs(org: str, kinds: set[str]) -> list[dict]:
    """The organization's active PRs the person checking opened, or approved as a reviewer."""
    headers, me = _ado_headers(), _ado_me(org)
    search = f"https://dev.azure.com/{org}/_apis/git/pullrequests?searchCriteria.status=active&$top=100&api-version=7.1"
    found: list[tuple[dict, str]] = []
    if "opened" in kinds:
        opened = _http_json(f"{search}&searchCriteria.creatorId={me}", headers).get("value") or []  # type: ignore[union-attr]
        found += [(pr, "opened") for pr in opened]
    if "approved" in kinds:
        for pr in _http_json(f"{search}&searchCriteria.reviewerId={me}", headers).get("value") or []:  # type: ignore[union-attr]
            mine = next((r for r in pr.get("reviewers") or [] if r.get("id") == me), None)
            if mine is not None and mine.get("vote") in {10, 5} and (pr.get("createdBy") or {}).get("id") != me:
                found.append((pr, "approved"))
    rows = []
    for pr, why in found:
        project, repo = pr["repository"]["project"]["name"], pr["repository"]["name"]
        rows.append({"url": f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}/_git/"
                            f"{urllib.parse.quote(repo)}/pullrequest/{pr['pullRequestId']}", "why": why})
    return rows


GITHUB_MINE = {"opened": "author:@me", "assigned": "assignee:@me -author:@me",
               "approved": "reviewed-by:@me -author:@me -assignee:@me"}


def github_my_prs(kinds: set[str], known: set[str]) -> list[dict]:
    """The open PRs the person checking opened, is assigned to, or approved (none anonymously)."""
    token = _github_token()
    if not token:
        return []
    headers = {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"}
    rows = []
    for why, qualifier in GITHUB_MINE.items():
        if why not in kinds:
            continue
        query = urllib.parse.quote(f"is:pr is:open {qualifier}")
        found = _http_json(f"https://api.github.com/search/issues?q={query}&sort=updated&per_page=50", headers)
        for item in found.get("items") or []:  # type: ignore[union-attr]
            url = item["html_url"]
            if GITHUB_URL.match(url) is None or same_pr(url) in known:
                continue
            if why == "approved" and not _github_approved(url, headers):
                continue
            rows.append({"url": url, "why": why})
    return rows


def _github_approved(url: str, headers: dict[str, str]) -> bool:
    """Whether the person checking's last review of the PR approves it."""
    match = GITHUB_URL.match(url)
    assert match is not None
    reviews = _http_json(f"https://api.github.com/repos/{match['owner']}/{match['repo']}/pulls/{match['id']}"
                         "/reviews?per_page=100", headers)
    me = _github_me(headers)
    states = [r.get("state") for r in reviews if (r.get("user") or {}).get("login") == me  # type: ignore[union-attr]
              and r.get("state") in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}]
    return bool(states) and states[-1] == "APPROVED"


ADO_BUILD_STATES = {"notStarted": "queued", "postponed": "queued", "inProgress": "running", "cancelling": "running"}
ADO_BUILD_RESULTS = {"succeeded": "succeeded", "partiallySucceeded": "partially succeeded", "failed": "failed",
                     "canceled": "canceled"}
GITHUB_RUN_STATES = {"queued": "queued", "waiting": "queued", "requested": "queued", "pending": "queued",
                     "in_progress": "running"}
GITHUB_RUN_RESULTS = {"success": "succeeded", "neutral": "succeeded", "failure": "failed", "timed_out": "failed",
                      "action_required": "failed", "startup_failure": "failed", "cancelled": "canceled",
                      "skipped": "canceled", "stale": "canceled"}
BUILD_RUNNING = {"queued", "running"}
BUILDS_PER_PLACE = 20


def ado_my_builds(org: str, project: str) -> list[dict]:
    """The project's latest builds the person checking queued by hand, and the CI their pushes
    started on a branch with no open PR (a PR's builds stay with the PR)."""
    base = f"https://dev.azure.com/{org}/{urllib.parse.quote(project)}"

    def builds(reason: str) -> list[dict]:
        return _http_json(f"{base}/_apis/build/builds?requestedFor={_ado_me(org)}&reasonFilter={reason}"
                          f"&$top={BUILDS_PER_PLACE}&queryOrder=queueTimeDescending&api-version=7.1",
                          _ado_headers())["value"]  # type: ignore[index]

    found = builds("manual")
    has_pr: dict[tuple[str, str], bool] = {}
    for reason in ("individualCI", "batchedCI"):
        try:
            pushed = builds(reason)
        except WatchError:
            continue
        for build in pushed:
            repo, ref = (build.get("repository") or {}).get("id", ""), build.get("sourceBranch") or ""
            if (repo, ref) not in has_pr:
                try:
                    has_pr[(repo, ref)] = bool(_http_json(
                        f"{base}/_apis/git/pullrequests?searchCriteria.repositoryId={repo}"
                        f"&searchCriteria.sourceRefName={urllib.parse.quote(ref)}&searchCriteria.status=active"
                        f"&$top=1&api-version=7.1", _ado_headers())["value"])  # type: ignore[index]
                except WatchError:
                    has_pr[(repo, ref)] = False
            if not has_pr[(repo, ref)]:
                found.append(build)
    found = sorted(found, key=lambda build: build.get("queueTime") or "", reverse=True)[:BUILDS_PER_PLACE]
    rows = []
    for build in found:
        status = ADO_BUILD_STATES.get(build["status"]) or ADO_BUILD_RESULTS.get(build.get("result") or "", "failed")
        # The build's repository is the one holding the YAML, a shared template repo at times: the
        # project says more.
        rows.append({
            "url": f"{base}/_build/results?buildId={build['id']}",
            "repo": project,
            "pipeline": build["definition"]["name"],
            "number": str(build["id"]),
            "branch": (build.get("sourceBranch") or "").removeprefix("refs/heads/"),
            "status": status,
            "requestedBy": (build.get("requestedFor") or {}).get("displayName", ""),
            "trigger": "manual" if build.get("reason") == "manual" else "push",
            "queued": _stamp(build.get("queueTime") or ""),
            "started": _stamp(build.get("startTime") or ""),
            "ended": _stamp(build.get("finishTime") or "") if status not in BUILD_RUNNING else "",
        })
    return rows


_GITHUB_ME: list[str] = []


def _github_me(headers: dict[str, str]) -> str:
    with _ADO_LOCK:
        if not _GITHUB_ME:
            _GITHUB_ME.append(_http_json("https://api.github.com/user", headers)["login"])  # type: ignore[index]
        return _GITHUB_ME[0]


def _github_headers() -> dict[str, str]:
    token = _github_token()
    return {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"} if token else {}


def github_pushed_repos() -> set[str]:
    """`owner/repo` of the repos the person checking pushed to in the last BUILD_HOURS hours, from
    their GitHub activity (private repos included with their token)."""
    headers = _github_headers()
    if not headers:
        return set()
    events = _http_json(f"https://api.github.com/users/{_github_me(headers)}/events?per_page=100", headers)
    return {event["repo"]["name"] for event in events  # type: ignore[union-attr]
            if event.get("type") == "PushEvent" and _recent_enough((event.get("created_at") or "")[:16] + "Z")}


def github_my_runs(owner: str, repo: str) -> list[dict]:
    """The repo's latest workflow runs the person checking dispatched by hand, and those their pushes
    started on a branch with no open PR (a PR's runs stay with the PR). None anonymously."""
    headers = _github_headers()
    if not headers:
        return []
    found = _http_json(f"https://api.github.com/repos/{owner}/{repo}/actions/runs?actor={_github_me(headers)}"
                       f"&per_page={2 * BUILDS_PER_PLACE}", headers)["workflow_runs"]  # type: ignore[index]
    found = [run for run in found if run.get("event") == "workflow_dispatch"
             or (run.get("event") == "push" and not run.get("pull_requests"))][:BUILDS_PER_PLACE]
    rows = []
    for run in found:
        status = GITHUB_RUN_STATES.get(run["status"]) or GITHUB_RUN_RESULTS.get(run.get("conclusion") or "", "failed")
        rows.append({
            "url": run["html_url"],
            "repo": repo,
            "pipeline": run.get("name") or run.get("path") or "workflow",
            "number": str(run["id"]),
            "branch": run.get("head_branch") or "",
            "status": status,
            "requestedBy": (run.get("actor") or {}).get("login", ""),
            "trigger": "push" if run.get("event") == "push" else "manual",
            "queued": _stamp(run.get("created_at") or ""),
            "started": _stamp(run.get("run_started_at") or ""),
            "ended": _stamp(run.get("updated_at") or "") if status not in BUILD_RUNNING else "",
        })
    return rows


ADO_STEP_STATES = {"succeeded": "succeeded", "succeededWithIssues": "issues", "failed": "failed",
                   "canceled": "canceled", "abandoned": "canceled", "skipped": "skipped"}
STEP_ISSUES = {"issues", "failed", "canceled"}
GITHUB_STEP_STATES = {"success": "succeeded", "failure": "failed", "cancelled": "canceled", "timed_out": "failed",
                      "skipped": "skipped", "neutral": "succeeded", "action_required": "failed"}
MAX_STEPS = 300


class AzureBuild:
    """One Azure DevOps build, from its results URL: its steps with issues, and a new run of it."""

    def __init__(self, match: re.Match[str]) -> None:
        self.base = f"https://dev.azure.com/{match['org']}/{match['project']}/_apis"
        self.id = match["id"]

    def get(self, path: str) -> dict:
        separator = "&" if "?" in path else "?"
        return _http_json(f"{self.base}/{path}{separator}api-version=7.1", _ado_headers())  # type: ignore[return-value]

    def steps(self) -> list[dict]:
        """Every task of the run in order, with its job; a task that failed, was canceled or
        succeeded with issues carries its messages (warnings marked) and its log's error lines."""
        records = self.get(f"build/builds/{self.id}/timeline").get("records") or []
        by_id = {record["id"]: record for record in records}

        def path(record: dict) -> tuple[int, ...]:
            """The record's place in the run: its stage's, phase's, job's and own order."""
            orders, seen = [], set()
            while record is not None and record["id"] not in seen:
                seen.add(record["id"])
                orders.append(record.get("order") or 0)
                record = by_id.get(record.get("parentId") or "")  # type: ignore[assignment]
            return tuple(reversed(orders))

        steps = []
        for record in sorted(records, key=path):
            state = ADO_STEP_STATES.get(record.get("result") or "", "running" if record.get("state") != "completed" else "")
            if record.get("type") != "Task" or not state:
                continue
            messages = []
            if state in STEP_ISSUES:
                messages = [("warning: " if issue.get("type") == "warning" else "") + (issue.get("message") or "")[:EXCERPT]
                            for issue in record.get("issues") or []]
                if (record.get("log") or {}).get("url"):
                    try:
                        tail = log_tail(_http_text(record["log"]["url"], _ado_headers()))
                    except WatchError:
                        tail = []
                    messages += [line[:EXCERPT] for line in tail if line not in messages]
            job = (by_id.get(record.get("parentId") or "") or {}).get("name") or ""
            steps.append({"name": record["name"], "job": job, "state": state, "errors": messages[:8]})
        return steps[:MAX_STEPS]

    def rerun(self) -> str:
        """Queues a new run of the same pipeline on the same branch with the same parameters, as
        the person checking; returns its URL."""
        build = self.get(f"build/builds/{self.id}")
        body: dict = {"definition": {"id": build["definition"]["id"]}, "sourceBranch": build.get("sourceBranch", ""),
                      "reason": "manual"}
        for key in ("parameters", "templateParameters"):
            if build.get(key):
                body[key] = build[key]
        queued = _http_json(f"{self.base}/build/builds?api-version=7.1", _ado_headers(), method="POST", body=body)
        return f"{self.base.removesuffix('/_apis')}/_build/results?buildId={queued['id']}"  # type: ignore[index]

    def name(self) -> str:
        return self.get(f"build/builds/{self.id}")["definition"]["name"]


class GitHubRun:
    """One GitHub Actions run, from its URL: its failed steps, and a re-run of it."""

    def __init__(self, match: re.Match[str]) -> None:
        self.base = f"https://api.github.com/repos/{match['owner']}/{match['repo']}"
        self.id = match["id"]
        token = _github_token()
        self.headers = {"X-GitHub-Api-Version": "2022-11-28", **({"Authorization": f"Bearer {token}"} if token else {})}

    def get(self, path: str) -> dict:
        return _http_json(f"{self.base}/{path}", self.headers)  # type: ignore[return-value]

    def steps(self) -> list[dict]:
        """Every step of every job in order; the first failed step of a failed job carries the
        job's failure annotations."""
        steps = []
        for job in self.get(f"actions/runs/{self.id}/jobs?per_page=100").get("jobs", []):
            messages = []
            if job.get("conclusion") in {"failure", "cancelled", "timed_out"}:
                try:
                    for annotation in self.get(f"check-runs/{job['id']}/annotations")[:10]:  # type: ignore[index]
                        if annotation.get("annotation_level") == "failure":
                            where = f"{annotation['path']}: " if annotation.get("path") else ""
                            messages.append(f"{where}{(annotation.get('message') or '')[:EXCERPT]}")
                except WatchError:
                    pass
            for step in job.get("steps", []):
                state = GITHUB_STEP_STATES.get(step.get("conclusion") or "", "running" if step.get("status") != "completed" else "")
                if not state:
                    continue
                errors = messages[:8] if state == "failed" else []
                if errors:
                    messages = []
                steps.append({"name": step["name"], "job": job["name"], "state": state, "errors": errors})
        return steps[:MAX_STEPS]

    def rerun(self) -> str:
        """Re-runs the whole workflow run (its URL stays the same)."""
        if "Authorization" not in self.headers:
            raise WatchError("GitHub: re-running needs GITHUB_TOKEN or `gh auth login`")
        _http_json(f"{self.base}/actions/runs/{self.id}/rerun", self.headers, method="POST")
        return f"{self.base.replace('https://api.github.com/repos/', 'https://github.com/')}/actions/runs/{self.id}"

    def name(self) -> str:
        return self.get(f"actions/runs/{self.id}").get("name") or "workflow"


def build_provider(url: str) -> AzureBuild | GitHubRun | None:
    if match := ADO_BUILD_URL.match(url):
        return AzureBuild(match)
    if match := GITHUB_RUN_URL.match(url):
        return GitHubRun(match)
    return None


def _steps_path(url: str) -> Path:
    return STEPS_DIR / f"{hashlib.sha1(url.encode()).hexdigest()[:16]}.json"


def build_details(build: AzureBuild | GitHubRun, url: str) -> None:
    """JSON: every step of the run with its job and state; a step with issues has its error lines.

    An ended run's steps no longer change: they are kept in STEPS_DIR (synced with the rest, so a
    computer that cannot reach the host still shows what another one read) and answered from there."""
    kept = _steps_path(url)
    if kept.exists():
        print(kept.read_text(encoding="utf-8"))
        return
    steps = build.steps()
    for step in steps:
        if step["state"] in STEP_ISSUES and not step["errors"]:
            step["errors"] = ["no step details kept: see the build log"]
    answer = json.dumps({"url": url, "steps": steps}, ensure_ascii=False)
    if steps and not any(step["state"] == "running" for step in steps):
        STEPS_DIR.mkdir(parents=True, exist_ok=True)
        kept.write_text(answer, encoding="utf-8")
    print(answer)


def rerun_build(build: AzureBuild | GitHubRun, url: str) -> None:
    name = build.name()
    # A GitHub re-run keeps the run's URL: its kept steps are those of the attempt before.
    _steps_path(url).unlink(missing_ok=True)
    print(f"relaunched {name}: {build.rerun()}")


def _recent_enough(stamp: str) -> bool:
    try:
        ended = datetime.strptime(stamp, "%Y-%m-%dT%H:%MZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return False
    return (datetime.now(timezone.utc) - ended).total_seconds() <= BUILD_HOURS * 3600


def fetch_builds(entries: list[tuple[Path, dict]], hosts: tuple[str, ...] = HOSTS,
                 only: list[str] | None = None) -> tuple[list[dict], list[str]]:
    """The user's pipeline runs (by hand, or from their pushes outside a PR), running ones first
    (newest queued first), then those ended in the last BUILD_HOURS hours (newest first): (rows, errors).

    Asked in the Azure DevOps projects and GitHub repos of the tracked and recent PRs, the GitHub
    repos the user pushed to lately, plus `azureProjects` (`org/project`) and `githubRepos`
    (`owner/repo`) in config.json. Only on `hosts`, and when `only` is given, only in the places of
    those run URLs; none when the user shows none (`runsPerRepo` 0).
    """
    if runs_per_repo() == 0:
        return [], []
    projects, repos = config("azureProjects"), config("githubRepos")
    for entry in [entry for _, entry in entries] + done_entries():
        if match := ADO_URL.match(entry["url"]):
            projects.add(f"{match['org'] or match['org2']}/{urllib.parse.unquote(match['project'])}")
        elif match := GITHUB_URL.match(entry["url"]):
            repos.add(f"{match['owner']}/{match['repo']}")
    if only is not None:
        projects = {_build_place(url) for url in only if ADO_BUILD_URL.match(url)}
        repos = {_build_place(url) for url in only if GITHUB_RUN_URL.match(url)}
    elif "github" in hosts:
        try:
            repos |= github_pushed_repos()
        except (WatchError, KeyError, TypeError):
            pass
    projects = projects if "ado" in hosts else set()
    repos = repos if "github" in hosts else set()
    jobs: list[tuple[str, Callable[[], list[dict]]]] = [
        (place, partial(ado_my_builds, *place.split("/", 1))) for place in sorted(projects)]
    jobs += [(place, partial(github_my_runs, *place.split("/", 1))) for place in sorted(repos)]

    def one(item: tuple[str, Callable[[], list[dict]]]) -> tuple[str, list[dict], str]:
        place, job = item
        try:
            return place, job(), ""
        except WatchError as error:
            return place, [], f"pipeline runs: {error}"
        except (KeyError, TypeError) as error:
            return place, [], f"pipeline runs: unexpected answer ({error!r})"

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, jobs))
    # A place that did not answer (unreachable from this computer, slow, down) keeps the runs last
    # found there, marked stale, until they are older than BUILD_HOURS.
    failed = {place for place, _, error in results if error}
    kept = [{**row, "stale": True} for row in cached_builds()
            if _build_place(row["url"]) in failed and _recent_enough(row["ended"] or row["queued"])]
    rows = [row for _, found, _ in results for row in found] + kept
    return order_builds(rows), [error for _, _, error in results if error]


def order_builds(rows: list[dict]) -> list[dict]:
    """Running ones first (newest queued first), then those ended in the last BUILD_HOURS hours."""
    running = sorted((row for row in rows if row["status"] in BUILD_RUNNING), key=lambda row: row["queued"], reverse=True)
    ended = sorted((row for row in rows if row["status"] not in BUILD_RUNNING and _recent_enough(row["ended"])),
                   key=lambda row: row["ended"], reverse=True)
    return running + ended


def _build_place(url: str) -> str:
    """The `org/project` or `owner/repo` a run's URL belongs to, as fetch_builds names its places."""
    if match := ADO_BUILD_URL.match(url):
        return f"{match['org']}/{urllib.parse.unquote(match['project'])}"
    if match := GITHUB_RUN_URL.match(url):
        return f"{match['owner']}/{match['repo']}"
    return ""


def builds_file() -> dict:
    """`builds`: the runs last found (by a check or a live status); `checked`: when."""
    if not BUILDS.exists():
        return {}
    return json.loads(BUILDS.read_text(encoding="utf-8"))


def cached_builds() -> list[dict]:
    return order_builds(shared_rows("builds", builds_file()))


def save_builds(builds: list[dict]) -> None:
    save(BUILDS, {"checked": _now(), "builds": builds})


def build_changes(before: dict, builds: list[dict]) -> list[str]:
    """One line per run that ended since the last check (one seen running then, or ended after it)."""
    was_running = {row["url"] for row in before.get("builds", []) if row["status"] in BUILD_RUNNING}
    since = before.get("checked", "")
    lines = []
    for row in builds:
        if row["status"] in BUILD_RUNNING or not (row["url"] in was_running or (since and row["ended"] >= since)):
            continue
        branch = f" ({row['branch']})" if row["branch"] else ""
        lines.append(f"{_plain(row['pipeline'], 60)} build {row['number']}{branch}: {row['status']} {row['url']}")
    return lines


def _plain(text: str, width: int) -> str:
    """Third-party text on one line, control characters out, cut at `width`: it is read by a model."""
    text = " ".join(re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", text).split())
    return text if len(text) <= width else text[: width - 1] + "…"


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
        return _github_me(self.headers) if self.headers else ""

    def snapshot(self) -> dict:
        pr = self.get(f"pulls/{self.id}")
        assert isinstance(pr, dict)
        paths = {"issue": f"issues/{self.id}/comments?per_page=100",
                 "review": f"pulls/{self.id}/comments?per_page=100",
                 "summary": f"pulls/{self.id}/reviews?per_page=100"}
        # All at once: each GitHub request waits about half a second.
        with ThreadPoolExecutor(max_workers=4) as pool:
            checks = pool.submit(self.checks, pr["head"]["sha"])
            found = dict(zip(paths, pool.map(self.get, paths.values())))
            checks = checks.result()
        comments = {}
        for kind in paths:
            for item in found[kind]:  # type: ignore[union-attr]
                if kind == "summary" and not item.get("body"):
                    continue
                # A deleted account comes back as `"user": null`.
                author = (item.get("user") or {}).get("login") or "ghost"
                comments[f"{kind}/{item['id']}"] = {
                    "author": author,
                    "author_id": author,
                    "text": (item.get("body") or "")[:EXCERPT],
                    "file": item.get("path"),
                }
        votes = {(r.get("user") or {}).get("login") or "ghost": r["state"].lower().replace("_", " ")
                 for r in found["summary"] if r.get("state") in {"APPROVED", "CHANGES_REQUESTED"}}  # type: ignore[union-attr]
        status = "merged" if pr.get("merged_at") else pr["state"]
        return {"title": pr["title"], "description": (pr.get("body") or "")[:DESCRIPTION], "status": status,
                "target": pr["base"]["ref"], "source": pr["head"]["ref"],
                "conflicts": pr.get("mergeable_state") == "dirty", "votes": votes, "comments": comments,
                "checks": checks, "updated": _stamp(pr.get("updated_at") or "")}

    def checks(self, sha: str) -> dict[str, dict]:
        """Check runs (GitHub Actions and apps) and commit statuses on the PR's head commit."""
        with ThreadPoolExecutor(max_workers=2) as pool:
            runs, statuses = pool.map(self.get, (f"commits/{sha}/check-runs?per_page=100", f"commits/{sha}/status"))
        checks = {}
        for run in runs["check_runs"]:  # type: ignore[index]
            state = run["conclusion"] if run["status"] == "completed" else run["status"]
            checks[run["name"]] = {"state": GITHUB_STATES.get(state, state), "required": None,
                                   "link": run.get("html_url"), "run": run["id"]}
        for status in statuses["statuses"]:  # type: ignore[index]
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

    def merge(self) -> None:
        """Merges the way the repository allows: squash first, else a merge commit, else a rebase."""
        repo = _http_json(self.base, self.post_headers())
        assert isinstance(repo, dict)
        if repo.get("allow_squash_merge", True):
            method = "squash"
        elif repo.get("allow_merge_commit", True):
            method = "merge"
        else:
            method = "rebase"
        _http_json(f"{self.base}/pulls/{self.id}/merge", self.post_headers(), method="PUT", body={"merge_method": method})

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
            for path in sorted(WATCH_DIR.glob("*.json")) if path not in (CONFIG, REVIEWS, BUILDS, ACKS, ISSUES)]


def reviews_file() -> dict:
    """`reviews`: the requests last found (by a check or a live status); `announced`: the URLs a
    check has reported, so a live status in between hides nothing from the next check."""
    if not REVIEWS.exists():
        return {}
    return json.loads(REVIEWS.read_text(encoding="utf-8"))


def cached_reviews() -> list[dict]:
    return sorted(shared_rows("reviews", reviews_file()), key=lambda row: row["updated"], reverse=True)


def save_reviews(reviews: list[dict], announced: list[str] | None = None) -> None:
    stored = reviews_file()
    save(REVIEWS, {
        "checked": _now(),
        "reviews": reviews,
        "announced": announced if announced is not None else stored.get("announced", []),
    })


def fetch_review_requests(entries: list[tuple[Path, dict]], hosts: tuple[str, ...] = HOSTS) -> tuple[list[dict], list[str]]:
    """Open PRs waiting for the user's review, newest first: (rows, errors).

    GitHub needs a token; Azure DevOps is asked per organization, those of the tracked PRs plus
    `azureOrgs` in config.json. Only on `hosts`; none when the user turned them off (`reviews`).
    """
    if not setting("reviews"):
        return [], []
    orgs = config("azureOrgs") if "ado" in hosts else set()
    for _, entry in entries:
        if "ado" in hosts and (match := ADO_URL.match(entry["url"])):
            orgs.add(match["org"] or match["org2"])
    jobs: list[tuple[str, Callable[[], list[dict]]]] = [("github", github_review_requests)] if "github" in hosts else []
    jobs += [(org, partial(ado_review_requests, org)) for org in sorted(orgs)]

    def one(item: tuple[str, Callable[[], list[dict]]]) -> tuple[str, list[dict], str]:
        place, job = item
        try:
            return place, job(), ""
        except WatchError as error:
            return place, [], f"review requests: {error}"
        except (KeyError, TypeError) as error:
            return place, [], f"review requests: unexpected answer ({error!r})"

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, jobs))
    # A host that did not answer keeps the requests last found there.
    failed = {place for place, _, error in results if error}
    kept = [row for row in cached_reviews() if _review_place(row["url"]) in failed]
    rows = sorted([row for _, found, _ in results for row in found] + kept, key=lambda row: row["updated"], reverse=True)
    return rows, [error for _, _, error in results if error]


def _review_place(url: str) -> str:
    if match := ADO_URL.match(url):
        return match["org"] or match["org2"]
    return "github" if GITHUB_URL.match(url) else ""


def github_followed_issues(seen: dict) -> list[dict]:
    """The GitHub issues the person checking follows (none anonymously): those involving them in any
    repo (opened, commented on, mentioned or assigned in) and those they subscribed to in the repos
    they own or belong to; the open ones and those closed in the last KEEP_DAYS days, newest first.
    An issue `seen` already knows carries the comments others posted since (`newComments`), so any
    computer reading the share can report them."""
    headers = _github_headers()
    if not headers:
        return []
    def ago(days: float, form: str) -> str:
        return datetime.fromtimestamp(time.time() - days * 86400, timezone.utc).strftime(form)

    active = float(setting("issueDays"))  # type: ignore[arg-type]
    # GitHub's subscribed list stops at the repos of the user and their organizations: the search
    # reaches the issues they opened or joined in anyone's repo, those active lately only, so an old
    # thread they once commented on stays out until it moves again.
    items: dict[str, dict] = {}
    for state in ("state=open", f"state=closed&since={ago(KEEP_DAYS, '%Y-%m-%dT%H:%M:%SZ')}"):
        found = _http_json(f"{GITHUB_API}/issues?filter=subscribed&{state}&sort=updated&per_page=100", headers)
        items.update({item["html_url"]: item for item in found if "pull_request" not in item})  # type: ignore[union-attr]
    for state in (f"is:open updated:>={ago(active, '%Y-%m-%d')}", f"closed:>={ago(KEEP_DAYS, '%Y-%m-%d')}"):
        query = urllib.parse.quote(f"is:issue involves:@me {state}")
        found = _http_json(f"{GITHUB_API}/search/issues?q={query}&sort=updated&per_page=100", headers)
        items.update({item["html_url"]: item for item in found.get("items") or []  # type: ignore[union-attr]
                      if "pull_request" not in item})
    me, rows = _github_me(headers), []
    for item in items.values():
        match = GITHUB_ISSUE_URL.match(item["html_url"])
        if match is None:
            continue
        rows.append({
            "url": item["html_url"],
            "repo": match["repo"],
            "owner": match["owner"],
            "number": match["id"],
            # Anyone can write a title, a label or a comment: kept to plain text, as the review requests.
            "title": _plain(item["title"] or "", 200),
            "author": _plain((item.get("user") or {}).get("login") or "ghost", 40),
            "state": item["state"],
            "reason": (item.get("state_reason") or "").replace("_", " "),
            "labels": sorted(_plain(label["name"] or "", 50) for label in item.get("labels") or []),
            "comments": item.get("comments", 0),
            "at": item.get("updated_at") or "",
            "updated": _stamp(item.get("updated_at") or ""),
            "closed": _stamp(item.get("closed_at") or ""),
        })

    def new_comments(row: dict) -> None:
        before = seen.get(row["url"])
        if not before or row["comments"] <= before.get("comments", 0) or row["at"] <= before.get("at", ""):
            return
        found = _http_json(f"{GITHUB_API}/repos/{row['owner']}/{row['repo']}/issues/{row['number']}/comments"
                           f"?since={before['at']}&per_page=100", headers)
        row["newComments"] = [
            {"author": _plain((comment.get("user") or {}).get("login") or "ghost", 40), "at": comment.get("created_at") or "",
             "text": _plain(comment.get("body") or "", EXCERPT)}
            for comment in found  # type: ignore[union-attr]
            if (comment.get("created_at") or "") > before["at"] and ((comment.get("user") or {}).get("login") or "") != me
        ]

    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(new_comments, rows))
    return sorted(rows, key=lambda row: row["at"], reverse=True)


def issues_file() -> dict:
    """`issues`: those last found; `seen`: each one as the user last saw it; `unread`: what a quiet
    check found and the user has not read; `dismissed`: the URLs the user stopped following here."""
    if not ISSUES.exists():
        return {}
    return json.loads(ISSUES.read_text(encoding="utf-8"))


def cached_issues() -> list[dict]:
    stored = issues_file()
    gone = set(stored.get("dismissed", []))
    rows = [row for row in shared_rows("issues", stored) if row["url"] not in gone]
    return sorted(rows, key=lambda row: row.get("at", ""), reverse=True)


def fetch_issues(hosts: tuple[str, ...] = HOSTS) -> tuple[list[dict], list[str]]:
    """The followed issues on `hosts` (GitHub only), or those last found when GitHub did not answer;
    none when the user turned them off (`issues`)."""
    if "github" not in hosts or not setting("issues"):
        return [], []
    stored = issues_file()
    try:
        rows, errors = github_followed_issues(stored.get("seen", {})), []
    except WatchError as error:
        rows, errors = cached_issues(), [f"issues: {error}"]
    except (KeyError, TypeError) as error:
        rows, errors = cached_issues(), [f"issues: unexpected answer ({error!r})"]
    gone = set(stored.get("dismissed", []))
    return [row for row in rows if row["url"] not in gone], errors


def issue_seen(row: dict) -> dict:
    return {"state": row["state"], "reason": row["reason"], "labels": row["labels"], "comments": row["comments"],
            "at": row["at"]}


def issue_changes(before: dict, row: dict, ignore: set[str], bots: set[str]) -> list[str]:
    """What changed on the issue since the user last saw it; nothing for an issue never seen."""
    if not before:
        return []
    lines = []
    if row["state"] != before.get("state"):
        lines.append("reopened" if row["state"] == "open" else f"closed ({row['reason'] or 'completed'})")
    lines += [f"labeled {label}" for label in row["labels"] if label not in before.get("labels", [])]
    lines += [f"unlabeled {label}" for label in before.get("labels", []) if label not in row["labels"]]
    for comment in row.get("newComments", []):
        if comment["at"] <= before.get("at", "") or comment["author"] in ignore:
            continue
        bot = " (bot)" if comment["author"] in bots else ""
        lines.append(f"new comment by {comment['author']}{bot}: {' '.join(comment['text'].split())}")
    return lines


def issue_label(row: dict) -> str:
    title = row["title"]
    return f"{row['repo']} #{row['number']} ({title[:57] + '...' if len(title) > 60 else title})"


def save_issues(rows: list[dict], seen: dict, unread: dict) -> None:
    save(ISSUES, {"checked": _now(), "issues": rows, "seen": seen, "unread": unread,
                  "dismissed": issues_file().get("dismissed", [])})


def read_issue(url: str) -> None:
    stored = issues_file()
    row = next((row for row in cached_issues() if row["url"] == url), None)
    if row is None and url not in stored.get("seen", {}):
        raise WatchError(f"not a followed issue: {url}")
    seen, unread = stored.get("seen", {}), stored.get("unread", {})
    if row is not None:
        seen[url] = issue_seen(row)
    unread.pop(url, None)
    save(ISSUES, {**stored, "seen": seen, "unread": unread})


def dismiss_issue(url: str) -> None:
    stored = issues_file()
    save(ISSUES, {**stored, "dismissed": sorted(set(stored.get("dismissed", [])) | {url})})
    print(f"no longer followed: {url} (`add` it to follow it again; unsubscribe on GitHub to stop its "
          "notifications too)")


def follow_issue(url: str) -> None:
    stored = issues_file()
    if url not in stored.get("dismissed", []):
        print(f"already followed when GitHub lists it (an issue you are involved in, active lately): {url}")
        return
    save(ISSUES, {**stored, "dismissed": sorted(set(stored["dismissed"]) - {url})})
    print(f"followed again: {url}")


AUTO_TRACK = {"opened": "opened by you", "assigned": "assigned to you", "approved": "approved by you"}


def auto_track_kinds() -> set[str]:
    """`autoTrack` in config.json: which of the user's own PRs are tracked without an `add` (all by default)."""
    if not CONFIG.exists():
        return set(AUTO_TRACK)
    kinds = json.loads(CONFIG.read_text(encoding="utf-8")).get("autoTrack", list(AUTO_TRACK))
    return set(kinds) & set(AUTO_TRACK)


def same_pr(url: str) -> str:
    """One spelling per PR, whatever the quoting and case of the URL it came from."""
    return urllib.parse.unquote(normalize(url)).lower()


def dismissed() -> set[str]:
    """The PRs the user stopped tracking: never tracked again on their own."""
    if not DISMISSED.exists():
        return set()
    return {same_pr(line) for line in DISMISSED.read_text(encoding="utf-8").splitlines() if line.strip()}


def save_dismissed(urls: set[str]) -> None:
    DISMISSED.parent.mkdir(parents=True, exist_ok=True)
    DISMISSED.write_text("".join(f"{url}\n" for url in sorted(urls)), encoding="utf-8", newline="\n")


def auto_track(entries: list[tuple[Path, dict]], hosts: tuple[str, ...] = HOSTS) -> tuple[list[str], list[str]]:
    """Starts tracking the user's open PRs nobody added (see `autoTrack`), appending them to
    `entries`: (one line per PR now tracked, errors).

    Asked on GitHub with a token, and in the Azure DevOps organizations of the tracked and recent
    PRs plus `azureOrgs`. Only on `hosts`; never when the user turned the open PRs off (`openPrs`).
    """
    kinds = auto_track_kinds()
    if not kinds or not setting("openPrs"):
        return [], []
    known = {same_pr(entry["url"]) for _, entry in entries} | dismissed()
    orgs = config("azureOrgs") if "ado" in hosts else set()
    for entry in [entry for _, entry in entries] + done_entries():
        if "ado" in hosts and (match := ADO_URL.match(entry["url"])):
            orgs.add(match["org"] or match["org2"])
    jobs: list[Callable[[], list[dict]]] = [partial(github_my_prs, kinds, known)] if "github" in hosts else []
    jobs += [partial(ado_my_prs, org, kinds) for org in sorted(orgs)]

    def one(job: Callable[[], list[dict]]) -> tuple[list[dict], str]:
        try:
            return job(), ""
        except WatchError as error:
            return [], f"your PRs: {error}"
        except (KeyError, TypeError, AttributeError) as error:
            return [], f"your PRs: unexpected answer ({error!r})"

    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(one, jobs))
    lines, errors = [], [error for _, error in results if error]
    for row in (row for found, _ in results for row in found):
        url = normalize(row["url"])
        if same_pr(url) in known:
            continue
        known.add(same_pr(url))
        try:
            seen = provider(url).snapshot()
        except WatchError as error:
            errors.append(f"{url}: {error}")
            continue
        except (KeyError, TypeError, AttributeError) as error:
            errors.append(f"{url}: unexpected answer ({error!r})")
            continue
        if seen["status"] in FINAL:
            continue
        entry = {"url": url, "note": AUTO_TRACK[row["why"]], "added": _now(), "checked": _now(), "seen": seen,
                 "auto": row["why"], **({"reviewed": True} if row["why"] == "approved" else {})}
        path = entry_path(url)
        save(path, entry)
        entries.append((path, entry))
        lines.append(f"{label(entry)}: now tracked ({AUTO_TRACK[row['why']]}), {seen['status']}, "
                     f"{ci_summary(seen['checks'])} {url}")
    return lines, errors


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
    for path in STEPS_DIR.glob("*.json"):
        if now.timestamp() - path.stat().st_mtime > KEEP_DAYS * 86400:
            path.unlink()


def save(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(entry, ensure_ascii=False, indent=1) + "\n", encoding="utf-8", newline="\n")


def config(key: str) -> set[str]:
    """`ignoreAuthors`: never reported; `bots`: reported, marked (bot), for the reader to triage."""
    if not CONFIG.exists():
        return set()
    return set(json.loads(CONFIG.read_text(encoding="utf-8")).get(key, []))


def config_value(key: str, default: object) -> object:
    if not CONFIG.exists():
        return default
    return json.loads(CONFIG.read_text(encoding="utf-8")).get(key, default)


SETTINGS = {"openPrs": True, "parked": True, "recent": True, "reviews": True, "runsPerRepo": BUILDS_PER_PLACE,
            "issues": True, "issueDays": ISSUE_DAYS}


def pane_settings() -> dict:
    """What the user chose in the PR pane's settings (the Configuration pane, pr-pane),
    which Claude Code keeps in its settings.json; {} without them."""
    path = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "settings.json"
    try:
        configs = json.loads(path.read_text(encoding="utf-8")).get("pluginConfigs") or {}
        key = next((key for key in configs if key == "pr-pane" or key.startswith("pr-pane@")), "")
        return (configs.get(key) or {}).get("options") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def setting(key: str) -> object:
    """What pr-watch looks up, reports and lists (SETTINGS): the pane's setting, else config.json's."""
    chosen = pane_settings()
    return chosen[key] if key in chosen else config_value(key, SETTINGS[key])


def runs_per_repo() -> int:
    try:
        return max(0, min(int(setting("runsPerRepo")), BUILDS_PER_PLACE))  # type: ignore[call-overload]
    except (TypeError, ValueError):
        return BUILDS_PER_PLACE


def shown_runs(builds: list[dict]) -> list[dict]:
    """The first `runsPerRepo` runs of each repo, in their order."""
    limit, count, kept = runs_per_repo(), {}, []
    for row in builds:
        count[row["repo"]] = count.get(row["repo"], 0) + 1
        if count[row["repo"]] <= limit:
            kept.append(row)
    return kept


def watched(entries: list[tuple[Path, dict]]) -> list[tuple[Path, dict]]:
    """The tracked PRs the user wants: the open ones (`openPrs`) and the parked ones (`parked`)."""
    wanted = {False: bool(setting("openPrs")), True: bool(setting("parked"))}
    return [(path, entry) for path, entry in entries if wanted[bool(entry.get("parked"))]]


def turned_off() -> list[str]:
    """The shared sections' lists this computer neither fetches nor shows."""
    on = {"reviews": bool(setting("reviews")), "builds": runs_per_repo() > 0, "issues": bool(setting("issues"))}
    return [name for name, is_on in on.items() if not is_on]


def host_of(url: str) -> str:
    """The shared section a PR, a review request or a run belongs to."""
    host = urllib.parse.urlparse(url).netloc.lower()
    if host == "github.com":
        return "github"
    return "ado" if host == "dev.azure.com" or host.endswith(".visualstudio.com") else ""


def _now_seconds() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _epoch(stamp: str) -> float:
    """Seconds since 1970 of a `_now` or `_now_seconds` stamp; 0 when missing or odd."""
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return 0.0


PANE_MINUTES = {"running": "minutesRunning", "runs": "minutesRuns", "prs": "minutesPrs", "lists": "minutesLists"}


def cache_minutes() -> dict[str, float]:
    """The pane's settings (`minutesRunning`…), else `cacheMinutes` in config.json, over CACHE_MINUTES;
    `idle`, from older setups, stands for `prs`."""
    given = config_value("cacheMinutes", {})
    given = given if isinstance(given, dict) else {}
    given = {"prs": given["idle"], **given} if "idle" in given else given
    chosen = pane_settings()
    given = {**given, **{part: chosen[key] for part, key in PANE_MINUTES.items() if key in chosen}}
    minutes = {}
    for part, default in CACHE_MINUTES.items():
        try:
            minutes[part] = max(0.0, float(given.get(part, default)))
        except (TypeError, ValueError):
            minutes[part] = default
    return minutes


_SHARED: dict = {}


def shared_local() -> dict:
    """This computer's copy of the shared snapshot: `sections` per host, the `etag` it was read
    with, and the hosts this computer could not reach lately (`unreachable`)."""
    if not _SHARED:
        try:
            _SHARED.update(json.loads(SHARED_LOCAL.read_text(encoding="utf-8")))
        except (OSError, ValueError):
            pass
        _SHARED.setdefault("sections", {})
    return _SHARED


KIND_OF = {"builds": ("runs", "running"), "reviews": ("lists",), "issues": ("lists",)}


def fetched_at(section: dict, kinds: tuple[str, ...]) -> str:
    """When one of these parts of a host's share was last fetched (the latest); a share from an
    older pr-watch was fetched all at once."""
    stamps = [(section.get("kinds") or {}).get(kind) or section.get("at", "") for kind in kinds]
    return max(stamps, key=_epoch)


def shared_rows(name: str, stored: dict) -> list[dict]:
    """The review requests or runs (`name`) to show: per host, the newer of what this computer
    recorded (`stored`, with its `checked`) and what the shared snapshot holds."""
    sections, rows = shared_local()["sections"], []
    for host in HOSTS:
        section = sections.get(host)
        if section and _epoch(fetched_at(section, KIND_OF[name])) > _epoch(stored.get("checked", "")):
            rows += section.get(name, [])
        else:
            rows += [row for row in stored.get(name, []) if host_of(row["url"]) == host]
    return rows + [row for row in stored.get(name, []) if host_of(row["url"]) not in HOSTS]


def shared_repo() -> str:
    """`owner/repo` of the config sync on GitHub, which carries the shared snapshot; "" when off."""
    setting = os.environ.get("PR_WATCH_SHARED", "").strip()
    if setting.lower() == "off" or config_value("sharedCache", True) is False:
        return ""
    if setting:
        return setting
    remote = _run("git", "-C", str(WATCH_DIR), "remote", "get-url", "origin")
    match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?/?$", remote)
    return f"{match[1]}/{match[2]}" if match else ""


def _machine() -> str:
    try:
        return (WATCH_DIR.parent / ".machine").read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _http_raw(url: str, headers: dict[str, str], method: str = "GET", body: object = None,
              timeout: float = 10) -> tuple[int, str, bytes]:
    """(status, ETag, body), a 304 or an error status included."""
    data = json.dumps(body).encode("utf-8") if body is not None else None
    extra = {"Content-Type": "application/json"} if data is not None else {}
    request = urllib.request.Request(url, data=data, method=method, headers={**extra, **headers})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.headers.get("ETag", ""), response.read()
    except urllib.error.HTTPError as error:
        return error.code, "", b""
    except (urllib.error.URLError, OSError) as error:
        raise WatchError(f"{url.split('?')[0]}: {getattr(error, 'reason', error)}") from error


def _shared_api() -> tuple[str, dict[str, str]]:
    repo, token = shared_repo(), _github_token()
    if not repo or not token:
        return "", {}
    return f"{GITHUB_API}/repos/{repo}", {"Authorization": f"Bearer {token}", "X-GitHub-Api-Version": "2022-11-28"}


def shared_pull() -> None:
    """Brings in the sections another computer shared since the last look, a section only when
    newer than this computer's: one conditional request, a 304 when nothing changed."""
    api, headers = _shared_api()
    if not api:
        return
    local = shared_local()
    asked = {**headers, "Accept": "application/vnd.github.raw+json"}
    if local.get("etag"):
        asked["If-None-Match"] = local["etag"]
    try:
        code, etag, body = _http_raw(f"{api}/contents/{SHARED_PATH}?ref={SHARED_BRANCH}", asked, timeout=5)
        remote = json.loads(body.decode("utf-8")) if code == 200 else None
    except (WatchError, ValueError):
        return
    if not isinstance(remote, dict):
        return
    local["etag"] = etag
    for host, section in (remote.get("sections") or {}).items():
        mine = local["sections"].get(host) or {}
        if host in HOSTS and isinstance(section, dict) and _epoch(section.get("at", "")) > _epoch(mine.get("at", "")):
            local["sections"][host] = section


def _branch_head(api: str, headers: dict[str, str]) -> str:
    code, _, body = _http_raw(f"{api}/git/ref/heads/{SHARED_BRANCH}", headers)
    return json.loads(body.decode("utf-8"))["object"]["sha"] if code == 200 else ""


def shared_push() -> None:
    """Shares this computer's sections as SHARED_BRANCH's only commit (no parent, the branch moved
    onto it): the branch never grows, and the sync's clones fetch one small commit. What another
    computer shared meanwhile is merged in first; the branch is read again just before it moves,
    and a move in between starts over once."""
    api, headers = _shared_api()
    local = shared_local()
    if not api or time.time() - _epoch(local.get("pushDenied", "")) < PUSH_DENIED_HOURS * 3600:
        return
    for _ in range(2):
        before = _branch_head(api, headers)
        shared_pull()
        content = json.dumps({"version": 1, "sections": local["sections"]}, ensure_ascii=False)
        code, _, body = _http_raw(f"{api}/git/trees", headers, "POST", {
            "tree": [{"path": SHARED_PATH, "mode": "100644", "type": "blob", "content": content}]})
        if code in (403, 404):
            # A token that may read the sync repo but not write it: nothing to share for a while.
            local["pushDenied"] = _now_seconds()
            raise WatchError(f"shared snapshot: HTTP {code} writing to the sync repo (token without write access?)")
        if code != 201:
            raise WatchError(f"shared snapshot: HTTP {code}")
        tree = json.loads(body.decode("utf-8"))["sha"]
        code, _, body = _http_raw(f"{api}/git/commits", headers, "POST",
                                  {"message": "chore(pr-watch): share the PR snapshot", "tree": tree, "parents": []})
        if code != 201:
            raise WatchError(f"shared snapshot: HTTP {code}")
        commit = json.loads(body.decode("utf-8"))["sha"]
        if _branch_head(api, headers) != before:
            continue
        if before:
            code, _, _ = _http_raw(f"{api}/git/refs/heads/{SHARED_BRANCH}", headers, "PATCH", {"sha": commit, "force": True})
        else:
            code, _, _ = _http_raw(f"{api}/git/refs", headers, "POST", {"ref": f"refs/heads/{SHARED_BRANCH}", "sha": commit})
        if code in (200, 201):
            local.pop("pushDenied", None)
            return
    raise WatchError("shared snapshot: another computer kept sharing at the same time")


def host_used(host: str, entries: list[tuple[Path, dict]]) -> bool:
    """Whether there is anything to look up on the host: GitHub with a token or a tracked PR there,
    Azure DevOps with a tracked or recent PR, or `azureOrgs`/`azureProjects`."""
    urls = [entry["url"] for _, entry in entries] + [entry["url"] for entry in done_entries()]
    if host == "github":
        return bool(_github_token()) or any(host_of(url) == "github" for url in urls)
    return bool(config("azureOrgs") or config("azureProjects")) or any(host_of(url) == "ado" for url in urls)


def _ci_running(pr: dict) -> bool:
    return ci_summary(pr["seen"].get("checks", {})).startswith("CI running")


def _running_runs(section: dict) -> list[str]:
    return [build["url"] for build in section.get("builds", []) if build["status"] in BUILD_RUNNING and not build.get("stale")]


def parts_due(mode: str, entries: list[tuple[Path, dict]]) -> dict[str, set[str]]:
    """What this `status` fetches, per host: nothing from the cache, every part of every host in use
    when live (the refresh button). On `auto`, each part of a host's share once it is older than its
    `cacheMinutes`: `runs` (a look for new pipeline runs), `prs` (every tracked PR), `lists` (review
    requests, the user's new PRs, followed issues), and in between `running` (only the runs in
    progress and the PRs whose CI runs). A PR tracked since the share was made brings the PRs in. A
    host this computer could not reach in the last UNREACHABLE_MINUTES is left alone."""
    if mode == "cached":
        return {}
    hosts = [host for host in HOSTS if host_used(host, entries)]
    if mode == "live":
        return {host: set(KINDS) for host in hosts}
    local, minutes, now, due = shared_local(), cache_minutes(), time.time(), {}
    for host in hosts:
        if now - _epoch(local.get("unreachable", {}).get(host, "")) < UNREACHABLE_MINUTES * 60:
            continue
        section = local["sections"].get(host)
        if not section:
            due[host] = set(KINDS)
            continue

        def older(kinds: tuple[str, ...], part: str) -> bool:
            return now - _epoch(fetched_at(section, kinds)) >= minutes[part] * 60

        parts = {kind for kind in KINDS if older((kind,), kind)}
        if any(host_of(entry["url"]) == host and entry["url"] not in section.get("prs", {})
               and _epoch(entry.get("added", "")) > _epoch(section.get("at", "")) for _, entry in entries):
            parts.add("prs")
        running = _running_runs(section) or any(_ci_running(pr) for pr in section.get("prs", {}).values())
        if running and not {"runs", "prs"} <= parts and older(("running", "runs", "prs"), "running"):
            parts.add("running")
        if parts:
            due[host] = parts
    return due


def fetch_section(host: str, entries: list[tuple[Path, dict]], parts: set[str] = set(KINDS),
                  before: dict | None = None) -> tuple[dict | None, list[str]]:
    """The `parts` of one host's share fetched now, over what it held `before`, or None when the host
    did not answer this computer (every lookup failed); the errors."""
    before = before or {}
    mine = [(path, entry) for path, entry in watched(entries) if host_of(entry["url"]) == host]
    if "prs" not in parts:
        mine = [(path, entry) for path, entry in mine if "running" in parts
                and _ci_running((before.get("prs") or {}).get(entry["url"]) or entry)]
    only = None if "runs" in parts else _running_runs(before) if "running" in parts else []
    lists = "lists" in parts
    nothing: Callable[[], tuple[list, list]] = lambda: ([], [])
    # The lookups at once: each waits on the host far more than it computes.
    with ThreadPoolExecutor(max_workers=5) as pool:
        tracking = pool.submit(auto_track, entries, (host,)) if lists else pool.submit(nothing)
        fetching = pool.submit(fetch_all, mine)
        asking = pool.submit(fetch_review_requests, entries, (host,)) if lists else pool.submit(nothing)
        listing = pool.submit(fetch_builds, entries, (host,), **({"only": only} if only else {})) if only != [] \
            else pool.submit(nothing)
        following = pool.submit(fetch_issues, (host,)) if lists else pool.submit(nothing)
        (_, errors), fetched = tracking.result(), fetching.result()
        (reviews, review_errors), (builds, build_errors) = asking.result(), listing.result()
        issues, issue_errors = following.result()
    errors += [f"{entry['url']}: {error}" for _, entry, _, _, error in fetched if error] + review_errors + build_errors \
        + issue_errors
    answered = not errors or any(now is not None for _, _, now, _, _ in fetched) \
        or any(not build.get("stale") for build in builds)
    if not answered:
        return None, errors
    at = _now_seconds()
    # Every PR read again replaces the share's; the PRs whose CI runs, read alone, update theirs.
    prs = {**({} if "prs" in parts else before.get("prs") or {}),
           **{entry["url"]: {"seen": now, "me": me, "at": at} for _, entry, now, me, _ in fetched if now is not None}}
    section = {**before, "at": at, "by": _machine(), "prs": prs,
               "kinds": {**(before.get("kinds") or {}), **{part: at for part in parts}}}
    if only is None:
        section["builds"] = builds
    elif only:
        # The runs in progress, read again; the other places' runs stay as they were.
        places = {_build_place(url) for url in only}
        section["builds"] = order_builds(builds + [row for row in before.get("builds", [])
                                                   if _build_place(row["url"]) not in places])
    if lists:
        section.update(reviews=reviews, issues=issues)
    return section, errors


def refresh_shared(mode: str, entries: list[tuple[Path, dict]]) -> tuple[list[str], list[str]]:
    """Reads the shared snapshot, fetches what is due on each host (see parts_due) and shares it:
    (the hosts fetched, errors). Saved on this computer either way."""
    shared_pull()
    local, errors, fetched = shared_local(), [], []
    due = parts_due(mode, entries)
    if due:
        with ThreadPoolExecutor(max_workers=len(due)) as pool:
            results = list(pool.map(lambda host: (host, *fetch_section(host, entries, due[host], local["sections"].get(host))),
                                    due))
        for host, section, found_errors in results:
            shared = local["sections"].get(host) or {}
            if section is None:
                local.setdefault("unreachable", {})[host] = _now_seconds()
                # Another computer shares this host: not reaching it from here is expected.
                if shared.get("by", "") in ("", _machine()):
                    errors += found_errors
                continue
            errors += found_errors
            local.get("unreachable", {}).pop(host, None)
            # What this computer's settings leave out stays as another computer last shared it.
            unwatched = {entry["url"] for _, entry in entries} - {entry["url"] for _, entry in watched(entries)}
            kept = {url: pr for url, pr in (shared.get("prs") or {}).items() if url in unwatched}
            local["sections"][host] = {**section, **{name: shared[name] for name in turned_off() if name in shared},
                                       "prs": {**kept, **section["prs"]}}
            fetched.append(host)
    if fetched:
        try:
            shared_push()
        except (WatchError, KeyError, ValueError) as error:
            errors.append(str(error) if isinstance(error, WatchError) else f"shared snapshot: unexpected answer ({error!r})")
    save(SHARED_LOCAL, local)
    return fetched, errors


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
    if GITHUB_ISSUE_URL.match(url):
        follow_issue(url)
        return
    path = entry_path(url)
    if same_pr(url) in (gone := dismissed()):
        save_dismissed(gone - {same_pr(url)})
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
        except (KeyError, TypeError, AttributeError) as error:
            return path, entry, None, "", f"{entry['url']}: unexpected answer ({error!r})"

    with ThreadPoolExecutor(max_workers=8) as pool:
        return list(pool.map(one, entries))


UNREAD_KEPT = 20


def grouped_errors(lines: list[str]) -> list[str]:
    """`<what>: <error>` lines, each error once with what it hit: a host that cannot be reached
    fails every PR, review list and run list on it the same way."""
    hit: dict[str, list[str]] = {}
    for line in lines:
        what, _, error = line.partition(": ")
        if not error:
            what, error = "", line
        match = ADO_URL.match(what) or GITHUB_URL.match(what)
        hit.setdefault(error, []).append(f"{match['repo']} #{match['id']}" if match else what)
    return [f"{error} ({', '.join(filter(None, whats))})" if any(whats) else error for error, whats in hit.items()]


def check(peek: bool, quiet: bool = False) -> None:
    """With `peek`, report without recording: the changes are reported again at the next check.
    With `quiet`, record and print nothing: each PR keeps its changes as `unread` until `read`.

    Comments by the person checking are left out.
    """
    ignore, bots, report, errors = config("ignoreAuthors"), config("bots"), [], []
    entries = load_entries()
    off = turned_off()
    for path, entry, now, me, error in fetch_all(watched(entries)):
        if now is None:
            errors.append(f"{entry['url']}: {error}")
            continue
        found = changes(entry, now, ignore | {me} - {""}, bots)
        if entry.get("parked"):
            found = []
        report += found
        if peek:
            continue
        if now["status"] in FINAL:
            save(DONE_DIR / path.name, {**entry, "checked": _now(), "ended": _now(), "seen": now})
            path.unlink()
            report.append(f"{label(entry)}: {now['status']}, no longer tracked")
        else:
            unread = entry.get("unread", [])
            if quiet:
                prefix = f"{label(entry)}: "
                fresh = [line.removeprefix(prefix) for line in found]
                unread = list(dict.fromkeys(unread + fresh))[-UNREAD_KEPT:]
            save(path, {**entry, "checked": _now(), "seen": now, "unread": unread})
    if not peek:
        found, found_errors = auto_track(entries)
        report += found
        errors += found_errors
    reviews, review_errors = fetch_review_requests(entries)
    announced = set(reviews_file().get("announced", []))
    report += [f"{row['repo']} #{row['number']} ({_plain(row['title'], 80)}): {_plain(row['author'], 40)} asks for "
               f"your review: {row['url']}" for row in reviews if row["url"] not in announced]
    errors += review_errors
    builds, build_errors = fetch_builds(entries)
    builds = shown_runs(builds)
    report += build_changes(builds_file(), builds)
    errors += build_errors
    issues, issue_errors = fetch_issues()
    errors += issue_errors
    stored = issues_file()
    seen, unread = stored.get("seen", {}), stored.get("unread", {})
    for row in issues:
        found = issue_changes(seen.get(row["url"], {}), row, ignore, bots)
        # Past the very first check, an issue not seen yet is new to the user, or an old one that moved.
        if row["url"] not in seen and "checked" in stored:
            found = [f"now followed ({row['state']}, {row['comments']} comment{'' if row['comments'] == 1 else 's'})"]
        report += [f"{issue_label(row)}: {line} {row['url']}" for line in found]
        seen[row["url"]] = issue_seen(row)
        if quiet and found:
            unread[row["url"]] = list(dict.fromkeys(unread.get(row["url"], []) + found))[-UNREAD_KEPT:]
    if not peek:
        # Saved even when a host failed: its requests, runs and issues are the ones last found there.
        # What the user turned off is left as it was, so turning it on again reports what changed since.
        if "reviews" not in off:
            save_reviews(reviews, announced=sorted(row["url"] for row in reviews))
        if "builds" not in off:
            save_builds(builds)
        if "issues" not in off:
            if not issue_errors:
                seen = {url: one for url, one in seen.items() if any(row["url"] == url for row in issues)}
            save_issues(issues, seen, {url: lines for url, lines in unread.items() if url in seen})
        prune_done()
    if quiet:
        return
    print("\n".join(report) if report else "No change.")
    if errors:
        print("Could not check:\n" + "\n".join(grouped_errors(errors)), file=sys.stderr)


def read(url: str) -> None:
    """The person has seen the PR's changes: its unread ones are cleared and, when the host answers,
    what it shows now is recorded as seen, so the next check does not bring them back."""
    if GITHUB_ISSUE_URL.match(normalize(url)):
        read_issue(normalize(url))
        return
    path = entry_path(normalize(url))
    if not path.exists():
        raise WatchError(f"not tracked: {url}")
    entry = json.loads(path.read_text(encoding="utf-8"))
    try:
        now = provider(entry["url"]).snapshot()
    except (WatchError, KeyError, TypeError, AttributeError):
        now = None
    if now is not None and now["status"] not in FINAL:
        entry = {**entry, "checked": _now(), "seen": now}
    save(path, {**entry, "unread": []})


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


def status(mode: str) -> None:
    """JSON for a pane or a script, from the records and the shared snapshot, each PR, review
    request and run as the newer of the two shows it; `mode` (`cached`, `auto`, `live`) says which
    hosts are fetched first (see parts_due). Records nothing but the PRs it starts tracking."""
    entries = load_entries()
    fetched_hosts, errors = refresh_shared(mode, entries)
    sections, off = shared_local()["sections"], turned_off()
    reviews = [] if "reviews" in off else cached_reviews()
    builds = [] if "builds" in off else shown_runs(cached_builds())
    ignore, bots, prs, acks = config("ignoreAuthors"), config("bots"), [], acks_file()
    builds = [{**build, "ack": ack_of(build["url"], _build_alert(build), acks),
               **({"stepsFile": str(_steps_path(build["url"]))} if _steps_path(build["url"]).exists() else {})}
              for build in builds]
    for _, entry in watched(entries):
        section = sections.get(host_of(entry["url"])) or {}
        shared = (section.get("prs") or {}).get(entry["url"])
        read_at = (shared or {}).get("at") or section.get("at", "")
        is_newer = shared is not None and _epoch(read_at) > _epoch(entry.get("checked", ""))
        now, me = (shared["seen"], shared.get("me", "")) if is_newer else (None, "")
        seen = now or entry["seen"]
        match = ADO_URL.match(entry["url"]) or GITHUB_URL.match(entry["url"])
        prefix = f"{label(entry)}: "
        news = [line.removeprefix(prefix) for line in changes(entry, now, ignore | {me} - {""}, bots)] if now else []
        news = [] if entry.get("parked") else list(dict.fromkeys(entry.get("unread", []) + news))
        prs.append({
            "url": entry["url"],
            "repo": match["repo"] if match else "",
            "number": match["id"] if match else "",
            "title": seen["title"],
            "description": seen.get("description", ""),
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
            "reviewed": bool(entry.get("reviewed")),
            "parked": bool(entry.get("parked")),
            "parkedWhy": entry.get("parkedWhy", ""),
            "ack": ack_of(entry["url"], _pr_alert(seen, news), acks),
            "changes": news,
            "updated": seen.get("updated", ""),
            "checked": read_at[:16] + "Z" if now else entry.get("checked", ""),
        })
    recent = []
    for entry in done_entries() if setting("recent") else []:
        match = ADO_URL.match(entry["url"]) or GITHUB_URL.match(entry["url"])
        recent.append({
            "url": entry["url"],
            "repo": match["repo"] if match else "",
            "number": match["id"] if match else "",
            "title": entry["seen"]["title"],
            "status": entry["seen"]["status"],
            "target": entry["seen"].get("target", ""),
            "reviewed": bool(entry.get("reviewed")),
            "ended": entry.get("ended", ""),
        })
    stored = issues_file()
    issues = []
    for row in [] if "issues" in off else cached_issues():
        news = issue_changes(stored.get("seen", {}).get(row["url"], {}), row, ignore, bots)
        issues.append({**{key: value for key, value in row.items() if key not in ("newComments", "at", "owner")},
                       "changes": list(dict.fromkeys(stored.get("unread", {}).get(row["url"], []) + news))})
    shares = {host: {"at": section.get("at", ""), "by": section.get("by", "")} for host, section in sections.items()}
    print(json.dumps({"live": mode != "cached", "fetched": fetched_hosts, "sections": shares, "prs": merge_order(prs),
                      "reviews": reviews, "builds": builds, "issues": issues, "recent": recent,
                      "errors": grouped_errors(errors)},
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
    """Approves, then tracks the PR as one the user reviewed, until it is merged."""
    url = normalize(url)
    pr = provider(url)
    pr.approve()
    if REVIEWS.exists():
        save_reviews([row for row in cached_reviews() if row["url"] != url])
    local = shared_local()
    for section in local["sections"].values():
        section["reviews"] = [row for row in section.get("reviews", []) if row["url"] != url]
    save(SHARED_LOCAL, local)
    path = entry_path(url)
    entry = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"url": url, "note": "", "added": _now()}
    seen = pr.snapshot()
    if seen["status"] not in FINAL:
        save(path, {**entry, "reviewed": True, "checked": _now(), "seen": seen})
    print(f"approved {url}")


def merge(url: str) -> None:
    """Merges the PR; a tracked one that is merged by then moves to the recent list at once."""
    url = normalize(url)
    pr = provider(url)
    pr.merge()
    path = entry_path(url)
    if path.exists():
        entry = json.loads(path.read_text(encoding="utf-8"))
        seen = pr.snapshot()
        if seen["status"] in FINAL:
            save(DONE_DIR / path.name, {**entry, "checked": _now(), "ended": _now(), "seen": seen})
            path.unlink()
        else:
            save(path, {**entry, "checked": _now(), "seen": seen})
    print(f"merged {url}")


def open_(url: str) -> None:
    if not any(pattern.match(url) for pattern in (ADO_URL, GITHUB_URL, ADO_BUILD_URL, GITHUB_RUN_URL, GITHUB_ISSUE_URL)):
        raise WatchError(f"unsupported PR, build or issue URL (Azure DevOps or GitHub): {url}")
    if not webbrowser.open(url):
        raise WatchError(f"no browser could open {url}")


def remove(url: str) -> None:
    if GITHUB_ISSUE_URL.match(normalize(url)):
        dismiss_issue(normalize(url))
        return
    path = entry_path(normalize(url))
    if not path.exists():
        raise WatchError(f"not tracked: {url}")
    path.unlink()
    save_dismissed(dismissed() | {same_pr(url)})
    print(f"stopped tracking {normalize(url)} (not tracked again on its own; `add` it to track it again)")


def park(url: str, why: str) -> None:
    """Kept and tracked, but quiet: its changes are recorded without being reported, until it is
    merged or closed (reported once, as usual) or `unpark`ed."""
    path = entry_path(normalize(url))
    if not path.exists():
        raise WatchError(f"not tracked: {url}")
    entry = json.loads(path.read_text(encoding="utf-8"))
    save(path, {**entry, "parked": _now(), "parkedWhy": why, "unread": []})
    print(f"parked {label(entry)}: changes are no longer reported (`unpark` to bring it back)")


def acks_file() -> dict:
    return json.loads(ACKS.read_text(encoding="utf-8")) if ACKS.exists() else {}


def _pr_alert(seen: dict, news: list[str]) -> dict:
    """What makes a PR need the user, as an ack compares it: what it waits for, a conflict, and the
    new comments not read yet."""
    return {"waiting": waiting_for(seen), "conflicts": bool(seen.get("conflicts")),
            "comments": sorted(line for line in news if line.startswith("new comment"))}


def _build_alert(build: dict) -> dict:
    return {"status": build.get("status", ""), "ended": build.get("ended", "")}


def ack_of(url: str, alert: dict, acks: dict) -> dict | None:
    """The user's ack of this alert, while it holds: the same state (a PR's comments read since are
    fine, a new one is not) and its date not passed yet."""
    ack = acks.get(url)
    if not ack:
        return None
    if ack.get("until") and datetime.now().strftime("%Y-%m-%d") > ack["until"]:
        return None
    was = ack.get("alert", {})
    if "comments" in alert:
        same = (was.get("waiting"), was.get("conflicts")) == (alert["waiting"], alert["conflicts"]) \
            and set(alert["comments"]) <= set(was.get("comments", []))
    else:
        same = was == alert
    return {"until": ack.get("until", ""), "note": ack.get("note", ""), "at": ack.get("at", "")} if same else None


def ack(url: str, until: str, note: str, shown: str = "") -> None:
    """Quiets a PR's or a run's current alert until it changes or `until` (YYYY-MM-DD) passes.

    `shown`: the PR's alert as a live `status` gave it (JSON of `waiting`, `conflicts`, `comments`), so
    a pane acknowledges what it shows without asking the host again."""
    if until and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", until):
        raise WatchError(f"--until takes a date as YYYY-MM-DD, not {until}")
    path = entry_path(normalize(url))
    given = json.loads(shown) if shown else None
    if given is not None and not (isinstance(given, dict) and isinstance(given.get("waiting"), str)
                                  and isinstance(given.get("comments", []), list)):
        raise WatchError("--alert takes {\"waiting\": ..., \"conflicts\": ..., \"comments\": [...]}")
    if path.exists() and given is not None:
        entry = json.loads(path.read_text(encoding="utf-8"))
        key, what = entry["url"], label(entry)
        alert = {"waiting": given["waiting"], "conflicts": bool(given.get("conflicts")),
                 "comments": sorted(str(line) for line in given.get("comments", []) if str(line).startswith("new comment"))}
    elif path.exists():
        entry = json.loads(path.read_text(encoding="utf-8"))
        # As a live status shows it, so the comments on screen are the ones acknowledged.
        seen, news = entry["seen"], entry.get("unread", [])
        try:
            pr = provider(entry["url"])
            now = pr.snapshot()
            prefix = f"{label(entry)}: "
            news = news + [line.removeprefix(prefix) for line in
                           changes(entry, now, config("ignoreAuthors") | {pr.me()} - {""}, config("bots"))]
            seen = now
        except (WatchError, KeyError, TypeError, AttributeError):
            pass
        key, alert, what = entry["url"], _pr_alert(seen, news), label(entry)
    elif build := next((row for row in cached_builds() if row["url"] == url.strip()), None):
        key, alert, what = build["url"], _build_alert(build), f"{build['pipeline']} #{build['number']}"
    else:
        raise WatchError(f"neither a tracked PR nor a listed run: {url}")
    acks = acks_file()
    acks[key] = {"alert": alert, "until": until, "note": note, "at": _now()}
    save(ACKS, acks)
    print(f"acknowledged {what}" + (f" until {until}" if until else "") + ": back if it changes")


def ack_all(given: str) -> None:
    """Acknowledges each alert of the JSON list `given` as `ack` does; one that cannot be is said at
    the end, after the others are acknowledged."""
    try:
        items = json.loads(given)
    except ValueError:
        items = None
    if not isinstance(items, list) or not all(isinstance(item, dict) and isinstance(item.get("url"), str) for item in items):
        raise WatchError("ack-all reads [{\"url\": ..., \"alert\": {...}}] on stdin")
    failed = []
    for item in items:
        try:
            ack(item["url"], "", "", json.dumps(item["alert"]) if item.get("alert") else "")
        except WatchError as error:
            failed.append(str(error))
    if failed:
        raise WatchError("; ".join(failed))


def unack(url: str) -> None:
    acks = acks_file()
    key = normalize(url) if entry_path(normalize(url)).exists() else url.strip()
    if acks.pop(key, None) is None:
        raise WatchError(f"not acknowledged: {url}")
    save(ACKS, acks)
    print(f"no longer acknowledged: {key}")


def unpark(url: str) -> None:
    path = entry_path(normalize(url))
    if not path.exists():
        raise WatchError(f"not tracked: {url}")
    entry = json.loads(path.read_text(encoding="utf-8"))
    entry.pop("parked", None)
    entry.pop("parkedWhy", None)
    save(path, entry)
    print(f"unparked {label(entry)}")


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


def main(argv: list[str]) -> int:
    command, args = (argv[0], argv[1:]) if argv else ("", [])
    try:
        if command == "add" and args:
            note = args[args.index("--note") + 1] if "--note" in args[1:-1] else ""
            add(args[0], note)
        elif command == "check":
            check(peek="--peek" in args, quiet="--quiet" in args)
        elif command == "read" and args:
            read(args[0])
        elif command == "list":
            list_()
        elif command == "status":
            status("live" if "--live" in args else "auto" if "--auto" in args else "cached")
        elif command == "open" and args:
            open_(args[0])
        # A build URL keeps its query (`?buildId=`): not normalized like a PR's.
        elif command == "details" and args and (build := build_provider(args[0].strip())):
            build_details(build, args[0].strip())
        elif command == "details" and args:
            details(args[0])
        elif command == "rerun" and args and (build := build_provider(args[0].strip())):
            rerun_build(build, args[0].strip())
        elif command == "rerun" and len(args) >= 2:
            rerun(args[0], " ".join(args[1:]))
        elif command == "approve" and args:
            approve(args[0])
        elif command == "merge" and args:
            merge(args[0])
        elif command == "remove" and args:
            for url in args:
                remove(url)
        elif command == "park" and args:
            park(args[0], args[args.index("--note") + 1] if "--note" in args[1:-1] else "")
        elif command == "unpark" and args:
            unpark(args[0])
        elif command == "ack" and args:
            ack(args[0], args[args.index("--until") + 1] if "--until" in args[1:-1] else "",
                args[args.index("--note") + 1] if "--note" in args[1:-1] else "",
                args[args.index("--alert") + 1] if "--alert" in args[1:-1] else "")
        elif command == "ack-all":
            ack_all(sys.stdin.read())
        elif command == "unack" and args:
            unack(args[0])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except WatchError as error:
        print(f"pr-watch: {error}", file=sys.stderr)
        return 1
    except (KeyError, TypeError, AttributeError) as error:
        print(f"pr-watch: unexpected answer from the host ({error!r})", file=sys.stderr)
        return 1
    finally:
        save_etags()
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    sys.exit(main(sys.argv[1:]))
