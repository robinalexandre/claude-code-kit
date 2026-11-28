"""``kb serve``: the index over HTTP, for the home agent and anything else on the network.

Standard library only. Every route but ``/health`` needs ``Authorization: Bearer <KB_TOKEN>``,
and the server refuses to start without a token. A background thread pulls the notes
repository and refreshes the index every few minutes, so the embedding model loads once and
every search, semantic ones included, answers in a fraction of a second.

Routes, all GET and JSON:

- ``/search?q=…&n=8&type=decision&topic=billing&trust=user&mode=auto|text|hybrid&all=1``
- ``/related?name=…&depth=2``
- ``/notes/<name>``: one note, front matter and body
- ``/stats``
- ``/graph``: every note with its place on a 3D map, its links, look-alikes and group
  (``kb graph --json``), with its ``rev`` as a strong ``ETag``; ``If-None-Match`` gives 304.
  Computed again by the refresh only when the notes changed, and kept next to the index.

With ``--repo-dir``, ``KB_CRYPT_KEY`` (the git-crypt key the sync exported, base64) opens the
folders the repository encrypts.
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
from kb.graph import GraphUnavailable, collect, refresh_map, related, stored_map
from kb.index import Index, row_extra
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
        self.data_dir = Path(db_path).parent
        self.lock = threading.Lock()
        self.refreshed_at: float | None = None
        self.last_error = ""
        # The graph's JSON and its rev, replaced together.
        self.graph_served: tuple[bytes, str] | None = None
        self.graph_error = ""
        self._stored_map = stored_map(self.data_dir)
        if self._stored_map[0] is not None:
            self._set_graph(self._stored_map[0])

    def refresh(self) -> dict[str, Any]:
        if self.repo_dir is not None:
            self.last_error = pull(self.repo_dir)
        roots = [r for r in self.roots if r.exists()]
        notes = load_notes(roots)
        with self.lock:
            stats = self.index.update(notes, roots)
        self.refreshed_at = time.time()
        self.refresh_graph()
        return {"notes": len(notes), **stats.__dict__}

    def refresh_graph(self) -> bool:
        """The map computed again when the notes changed; the last one kept on a failure."""
        try:
            with self.lock:
                data = collect(self.index)
            graph, state, changed = refresh_map(data, self.data_dir, stored=self._stored_map)
        except GraphUnavailable as exc:
            self.graph_error = str(exc)
            return False
        except Exception as exc:  # noqa: BLE001 - the server must outlive one bad layout
            self.graph_error = f"graph: {type(exc).__name__}: {exc}"
            log.exception("graph failed")
            return False
        self.graph_error = ""
        self._stored_map = (graph, state)
        if changed or self.graph_served is None:
            self._set_graph(graph)
        return changed

    def _set_graph(self, graph: dict[str, Any]) -> None:
        body = json.dumps(graph, ensure_ascii=False, separators=(",", ":")).encode()
        self.graph_served = (body, str(graph.get("rev") or ""))

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
            nodes, edges = related(self.index, name, depth)
        return {"nodes": nodes, "edges": [list(e) for e in edges]}

    def note(self, name: str) -> dict[str, Any] | None:
        with self.lock:
            row = self.index.get(name.strip().lower())
        if row is None:
            return None
        data = {k: row[k] for k in row.keys() if k not in ("id", "hash", "rank")}
        data["topics"] = json.loads(data["topics"])
        data["extra"] = row_extra(row)
        # The graph's node carries the whole hash: a reader can tell it is the same file.
        data["rev"] = row["hash"][:12]
        return data

    def stats(self) -> dict[str, Any]:
        with self.lock:
            stats = self.index.stats()
        stats["refreshed_at"] = self.refreshed_at
        stats["last_error"] = self.last_error or self.graph_error
        served = self.graph_served
        stats["graph_rev"] = served[1] if served else None
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


def git(args: list[str], cwd: Path | None, token: str | None, check: bool = True) -> str:
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
        if not check:
            return ""
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


def unlock(repo_dir: Path, key_b64: str | None) -> None:
    """Opens the folders the repository encrypts with git-crypt, with the exported key given
    as base64 (the sync's `crypt export`). The key touches the disk only for the call, in a
    file of the clone's .git that git-crypt reads and that is removed at once; without a key,
    or once unlocked, nothing happens."""
    if not key_b64 or not (repo_dir / ".git").is_dir():
        return
    if git(["config", "--get", "filter.git-crypt.smudge"], repo_dir, None, check=False):
        return
    key_file = repo_dir / ".git" / "git-crypt-key.tmp"
    try:
        key_file.write_bytes(base64.b64decode("".join(key_b64.split()), validate=True))
        key_file.chmod(0o600)
        done = subprocess.run(  # noqa: S603 - fixed program, a path built here
            ["git-crypt", "unlock", str(key_file)],  # noqa: S607 - git-crypt from PATH
            cwd=repo_dir,
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT,
            check=False,
        )
        if done.returncode != 0:
            log.warning("git-crypt unlock: %s", done.stderr.strip() or done.stdout.strip())
        else:
            log.info("encrypted folders unlocked")
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        log.warning("git-crypt unlock: %s", exc)
    finally:
        key_file.unlink(missing_ok=True)


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
            elif url.path == "/graph":
                self.reply_graph()
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

    def reply_graph(self) -> None:
        served = self.knowledge.graph_served
        if served is None:
            error = self.knowledge.graph_error or "the graph is not built yet"
            self.reply(HTTPStatus.SERVICE_UNAVAILABLE, {"error": error})
            return
        body, rev = served
        etag = f'"{rev}"'
        if etag_matches(self.headers.get("If-None-Match", ""), rev):
            self.send_response(HTTPStatus.NOT_MODIFIED)
            self.send_header("ETag", etag)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        self.reply(HTTPStatus.OK, body, {"ETag": etag})

    def reply(self, status: HTTPStatus, data: Any, headers: dict[str, str] | None = None) -> None:
        if isinstance(data, bytes):
            body = data
        else:
            body = json.dumps(data, ensure_ascii=False, default=str).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)


def etag_matches(header: str, rev: str) -> bool:
    """``If-None-Match`` names ``rev`` (quoted, weak or not), or is ``*``."""
    for tag in header.split(","):
        tag = tag.strip()
        if tag == "*" or (rev and tag.removeprefix("W/") == f'"{rev}"'):
            return True
    return False


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
