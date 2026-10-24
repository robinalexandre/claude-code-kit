"""``kb serve``: the index over HTTP, for the home agent and anything else on the network.

Standard library only. Every route but ``/health`` needs ``Authorization: Bearer <KB_TOKEN>``,
and the server refuses to start without a token. A background thread pulls the notes
repository and refreshes the index every few minutes, so the embedding model loads once and
every search, semantic ones included, answers in a fraction of a second.

Routes, all GET and JSON:

- ``/search?q=…&n=8&type=decision&topic=qonto&trust=user&mode=auto|text|hybrid&all=1``
- ``/related?name=…&depth=2``
- ``/notes/<name>``: one note, front matter and body
- ``/stats``
"""

from __future__ import annotations

import base64
import hmac
import json
import logging
import os
import subprocess
import threading
import time
from datetime import date
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

from kb.embed import Embedder
from kb.index import Index
from kb.notes import load_notes

log = logging.getLogger("kb.serve")
MAX_LIMIT = 30
MAX_DEPTH = 4
MAX_QUERY_CHARS = 1000
GIT_TIMEOUT = 120


class Knowledge:
    """The index plus the notes it comes from, refreshed on demand or every so often."""

    def __init__(
        self,
        db_path: Path,
        embedder: Embedder | None,
        roots: list[Path],
        repo_dir: Path | None = None,
    ) -> None:
        self.index = Index(db_path, embedder, shared=True)
        self.roots = roots
        self.repo_dir = repo_dir
        self.lock = threading.Lock()
        self.refreshed_at: float | None = None
        self.last_error = ""

    def refresh(self) -> dict[str, Any]:
        if self.repo_dir is not None:
            self.last_error = pull(self.repo_dir)
        roots = [r for r in self.roots if r.exists()]
        notes = load_notes(roots)
        with self.lock:
            stats = self.index.update(notes, roots)
        self.refreshed_at = time.time()
        return {"notes": len(notes), **stats.__dict__}

    def refresh_forever(self, every: float) -> None:
        while True:
            time.sleep(every)
            try:
                self.refresh()
            except Exception as exc:  # noqa: BLE001 - the server must outlive one bad pull
                self.last_error = str(exc)
                log.warning("refresh failed: %s", exc)

    def search(self, params: dict[str, list[str]]) -> list[dict[str, Any]]:
        query = first(params, "q")[:MAX_QUERY_CHARS]
        if not query.strip():
            raise ValueError("q is required")
        limit = clamp(first(params, "n", "8"), 1, MAX_LIMIT)
        on = first(params, "on")
        valid_on = None
        if not first(params, "all"):
            valid_on = date.fromisoformat(on) if on else date.today()
        mode = first(params, "mode", "auto")
        if mode not in ("auto", "text", "hybrid"):
            raise ValueError("mode is auto, text or hybrid")
        with self.lock:
            hits = self.index.search(
                query,
                limit=limit,
                types=params.get("type") or None,
                topic=first(params, "topic") or None,
                valid_on=valid_on,
                trust=params.get("trust") or None,
                mode=mode,
            )
        return [h.as_dict() for h in hits]

    def related(self, params: dict[str, list[str]]) -> dict[str, Any]:
        name = first(params, "name").strip().lower()
        if not name:
            raise ValueError("name is required")
        depth = clamp(first(params, "depth", "2"), 1, MAX_DEPTH)
        with self.lock:
            nodes, edges = self.index.related(name, depth)
        return {"nodes": nodes, "edges": [list(e) for e in edges]}

    def note(self, name: str) -> dict[str, Any] | None:
        with self.lock:
            row = self.index.get(name.strip().lower())
        if row is None:
            return None
        data = {k: row[k] for k in row.keys() if k not in ("id", "hash")}
        data["topics"] = json.loads(data["topics"])
        return data

    def stats(self) -> dict[str, Any]:
        with self.lock:
            stats = self.index.stats()
        stats["refreshed_at"] = self.refreshed_at
        stats["last_error"] = self.last_error
        return stats


def first(params: dict[str, list[str]], key: str, default: str = "") -> str:
    values = params.get(key)
    return values[0] if values else default


def clamp(text: str, low: int, high: int) -> int:
    try:
        return max(low, min(high, int(text)))
    except ValueError as exc:
        raise ValueError(f"{text!r} is not a number") from exc


def git_env(token: str | None) -> dict[str, str]:
    """git's environment with the token as an Authorization header, so it is never written
    to the clone's config on the volume."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_CONFIG")}
    env.setdefault("GIT_TERMINAL_PROMPT", "0")
    if token:
        basic = base64.b64encode(f"x-access-token:{token}".encode()).decode()
        env["GIT_CONFIG_COUNT"] = "1"
        env["GIT_CONFIG_KEY_0"] = "http.https://github.com/.extraheader"
        env["GIT_CONFIG_VALUE_0"] = f"Authorization: Basic {basic}"
    return env


def git(args: list[str], cwd: Path | None, token: str | None) -> str:
    done = subprocess.run(  # noqa: S603 - arguments built here
        ["git", *args],  # noqa: S607 - git from PATH, as everywhere
        cwd=cwd,
        env=git_env(token),
        capture_output=True,
        text=True,
        timeout=GIT_TIMEOUT,
        check=False,
    )
    if done.returncode != 0:
        raise RuntimeError(f"git {args[0]}: {done.stderr.strip() or done.stdout.strip()}")
    return done.stdout


def clone_if_needed(repo_dir: Path, repo: str, token: str | None) -> None:
    """``repo`` is ``owner/name`` on GitHub or a full URL."""
    if (repo_dir / ".git").is_dir():
        return
    url = repo if "://" in repo or repo.startswith("git@") else f"https://github.com/{repo}.git"
    repo_dir.parent.mkdir(parents=True, exist_ok=True)
    log.info("cloning %s", url if not token else repo)
    git(["clone", "--quiet", "--depth", "50", url, str(repo_dir)], None, token)


def pull(repo_dir: Path) -> str:
    """Fast-forward the clone; returns an error message or an empty string."""
    if not (repo_dir / ".git").is_dir():
        return ""
    try:
        git(["pull", "--quiet", "--ff-only"], repo_dir, os.environ.get("KB_GITHUB_TOKEN"))
        return ""
    except (RuntimeError, subprocess.TimeoutExpired) as exc:
        log.warning("%s", exc)
        return str(exc)


class Handler(BaseHTTPRequestHandler):
    knowledge: Knowledge
    token: str
    server_version = "kb"
    sys_version = ""

    def log_message(self, fmt: str, *args: Any) -> None:
        log.info("%s " + fmt, self.address_string(), *args)

    def do_GET(self) -> None:  # noqa: N802 - http.server's name
        url = urlsplit(self.path)
        if url.path == "/health":
            self.reply(HTTPStatus.OK, {"ok": True})
            return
        if not self.authorized():
            self.reply(HTTPStatus.UNAUTHORIZED, {"error": "bearer token required"})
            return
        params = parse_qs(url.query, keep_blank_values=False)
        try:
            if url.path == "/search":
                self.reply(HTTPStatus.OK, {"hits": self.knowledge.search(params)})
            elif url.path == "/related":
                self.reply(HTTPStatus.OK, self.knowledge.related(params))
            elif url.path.startswith("/notes/") and len(url.path) > len("/notes/"):
                note = self.knowledge.note(url.path[len("/notes/") :])
                if note is None:
                    self.reply(HTTPStatus.NOT_FOUND, {"error": "unknown note"})
                else:
                    self.reply(HTTPStatus.OK, note)
            elif url.path == "/stats":
                self.reply(HTTPStatus.OK, self.knowledge.stats())
            else:
                self.reply(HTTPStatus.NOT_FOUND, {"error": "no such route"})
        except ValueError as exc:
            self.reply(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except Exception as exc:  # noqa: BLE001 - one bad request must not end the server
            log.exception("request failed")
            self.reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": type(exc).__name__})

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, value = header.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(value.strip(), self.token)

    def reply(self, status: HTTPStatus, data: Any) -> None:
        body = json.dumps(data, ensure_ascii=False, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def make_server(knowledge: Knowledge, token: str, host: str, port: int) -> ThreadingHTTPServer:
    if len(token) < 16:
        raise ValueError("KB_TOKEN must be at least 16 characters")
    handler = type("KnowledgeHandler", (Handler,), {"knowledge": knowledge, "token": token})
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def serve(
    knowledge: Knowledge, token: str, host: str, port: int, pull_every: float
) -> None:  # pragma: no cover - the loop; make_server and Knowledge are tested
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(message)s")
    result = knowledge.refresh()
    log.info("index ready: %s", result)
    if pull_every > 0:
        threading.Thread(
            target=knowledge.refresh_forever, args=(pull_every,), daemon=True, name="refresh"
        ).start()
    server = make_server(knowledge, token, host, port)
    log.info("listening on %s:%s", host, port)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
