"""``kb``: index notes, search them, walk their links, extract a day of transcripts."""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, timedelta
from pathlib import Path

from kb.embed import get_embedder
from kb.extract import extract_day
from kb.index import Index
from kb.notes import load_notes

SYNC = Path.home() / ".claude-sync"
# In the config sync when there is one, so the notes reach every computer; else local.
DEFAULT_NOTES = (SYNC if SYNC.is_dir() else Path.home() / ".claude") / "knowledge"
# Claude Code's own memory, as the config sync stores it, reads as notes too.
MEMORY_FOLDERS = (SYNC / "memory", SYNC / "memory-repos", SYNC / "memory-folders")
DEFAULT_DB = Path.home() / ".claude" / "kb" / "index.sqlite"


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        parser.print_help()
        return 1
    try:
        return args.func(args) or 0
    except KeyboardInterrupt:
        return 130


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="kb", description=__doc__)
    parser.add_argument(
        "--notes",
        action="append",
        type=Path,
        help=f"notes folder, repeatable (default: $KB_NOTES or {DEFAULT_NOTES})",
    )
    parser.add_argument("--db", type=Path, help=f"index file (default: $KB_DB or {DEFAULT_DB})")
    parser.add_argument(
        "--embed", choices=["fastembed", "hash", "none"], help="embedder (default: $KB_EMBED)"
    )
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    sub = parser.add_subparsers()

    p = sub.add_parser("index", help="bring the index up to date with the notes")
    p.set_defaults(func=cmd_index)

    p = sub.add_parser("search", help="text and semantic search")
    p.add_argument("query", nargs="+")
    p.add_argument("-n", "--limit", type=int, default=8)
    p.add_argument("--type", action="append", dest="types")
    p.add_argument("--topic")
    p.add_argument("--trust", action="append")
    p.add_argument("--all", action="store_true", help="include notes no longer valid today")
    p.add_argument("--on", type=date.fromisoformat, help="notes valid on that date")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument(
        "--text", action="store_true", help="full text only, never loads the model (fast)"
    )
    mode.add_argument(
        "--hybrid", action="store_true", help="always add the semantic search to the text one"
    )
    p.set_defaults(func=cmd_search)

    p = sub.add_parser("related", help="notes linked to one, through up to DEPTH links")
    p.add_argument("name")
    p.add_argument("--depth", type=int, default=2)
    p.add_argument("--mermaid", action="store_true", help="print a Mermaid mind map")
    p.set_defaults(func=cmd_related)

    p = sub.add_parser("show", help="print a note")
    p.add_argument("name", nargs="+")
    p.add_argument("--brief", action="store_true", help="front matter and the first lines only")
    p.set_defaults(func=cmd_show)

    p = sub.add_parser("check", help="report malformed notes and dangling links")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("stats", help="what the index holds")
    p.set_defaults(func=cmd_stats)

    p = sub.add_parser("extract", help="reduce a day of Claude Code transcripts to Markdown")
    p.add_argument("--day", type=date.fromisoformat, help="YYYY-MM-DD (default: yesterday)")
    p.add_argument("--projects", type=Path, help="Claude Code projects folder")
    p.add_argument("--out", type=Path, help="output folder (default: ~/.claude/kb/transcripts)")
    p.set_defaults(func=cmd_extract)

    p = sub.add_parser("curate", help="have Claude turn a day of transcripts into notes")
    p.add_argument("--day", type=date.fromisoformat, help="YYYY-MM-DD (default: yesterday)")
    p.add_argument(
        "--transcripts", type=Path, help="extract output (default: ~/.claude/kb/transcripts)"
    )
    p.add_argument("--projects", type=Path, help="Claude Code projects folder")
    p.add_argument(
        "--model",
        help="Claude model (default: $KB_CURATE_MODEL or sonnet); $KB_CURATE_ENGINE picks "
        "the subscription (claude -p, the default) or the API",
    )
    p.add_argument(
        "--max-new", type=int, help="new notes per day at most (default: $KB_CURATE_MAX or 15)"
    )
    p.add_argument(
        "--material",
        type=Path,
        help="curate this Markdown file instead: what another agent wrote about its own work",
    )
    p.add_argument("--name", help="who wrote the material (default: the file's name)")
    p.set_defaults(func=cmd_curate)

    p = sub.add_parser("serve", help="serve the index over HTTP (token in $KB_TOKEN)")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8800)
    p.add_argument(
        "--repo-dir",
        type=Path,
        help="git clone of the notes, pulled before each refresh; cloned from $KB_REPO"
        " (owner/repo or URL, with $KB_GITHUB_TOKEN) when missing",
    )
    p.add_argument(
        "--pull-every",
        type=float,
        help="seconds between refreshes, 0 for none (default: $KB_PULL_SECONDS or 300)",
    )
    p.set_defaults(func=cmd_serve)
    return parser


def notes_roots(args: argparse.Namespace) -> list[Path]:
    if args.notes:
        return args.notes
    env = os.environ.get("KB_NOTES")
    if env:
        return [Path(p) for p in env.split(os.pathsep) if p]
    return [DEFAULT_NOTES, *MEMORY_FOLDERS]


def open_index(args: argparse.Namespace, with_embedder: bool = True) -> Index:
    db = args.db or Path(os.environ.get("KB_DB") or DEFAULT_DB)
    embedder = get_embedder(args.embed) if with_embedder else None
    return Index(db, embedder)


def emit(args: argparse.Namespace, data: object, text: str) -> None:
    print(json.dumps(data, ensure_ascii=False, indent=2, default=str) if args.json else text)


def cmd_index(args: argparse.Namespace) -> int:
    roots = [r for r in notes_roots(args) if r.exists()]
    if not roots:
        print("No notes folder found: " + ", ".join(str(r) for r in notes_roots(args)))
        return 1
    notes = load_notes(roots)
    index = open_index(args)
    stats = index.update(notes, roots)
    emit(
        args,
        stats.__dict__,
        f"{len(notes)} notes: {stats.added} added, {stats.changed} changed,"
        f" {stats.removed} removed, {stats.unchanged} unchanged;"
        f" {stats.chunks_embedded} chunks embedded",
    )
    return 0


def cmd_search(args: argparse.Namespace) -> int:
    index = open_index(args)
    valid_on = None if args.all else (args.on or date.today())
    hits = index.search(
        " ".join(args.query),
        limit=args.limit,
        types=args.types,
        topic=args.topic,
        valid_on=valid_on,
        trust=args.trust,
        mode="text" if args.text else "hybrid" if args.hybrid else "auto",
    )
    lines = []
    for hit in hits:
        tag = f"{hit.type}" + (f", {hit.trust}" if hit.trust != "agent" else "")
        lines.append(f"{hit.name}  [{tag}]  {hit.title}")
        lines.append(f"    {hit.snippet}")
        lines.append(f"    {hit.path}")
    emit(args, [h.as_dict() for h in hits], "\n".join(lines) or "No match.")
    return 0 if hits else 1


def cmd_related(args: argparse.Namespace) -> int:
    index = open_index(args, with_embedder=False)
    nodes, edges = index.related(args.name, args.depth)
    if args.mermaid:
        lines = ["mindmap", f"  root(({args.name}))"]
        children: dict[str, list[str]] = {}
        for src, dst in edges:
            children.setdefault(src, []).append(dst)
            children.setdefault(dst, []).append(src)
        placed = {args.name.lower()}

        def walk(name: str, indent: int) -> None:
            for child in sorted(children.get(name, [])):
                if child in placed:
                    continue
                placed.add(child)
                lines.append("  " * indent + child)
                walk(child, indent + 1)

        walk(args.name.lower(), 2)
        emit(args, {"nodes": nodes, "edges": edges}, "\n".join(lines))
        return 0
    lines = []
    for node in nodes:
        if node["via"] != "link":
            continue
        marker = "?" if node["type"] == "missing" else node["type"]
        lines.append(f"{'  ' * node['depth']}{node['name']}  [{marker}]  {node['title']}")
    by_topic = [n for n in nodes if n["via"] != "link"]
    if by_topic:
        lines.append("")
        lines.append("Same topics:")
        for node in by_topic:
            lines.append(f"  {node['name']}  [{node['type']}, {node['via']}]  {node['title']}")
    emit(args, {"nodes": nodes, "edges": edges}, "\n".join(lines) or "Unknown note.")
    return 0


BRIEF_CHARS = 600


def cmd_show(args: argparse.Namespace) -> int:
    index = open_index(args, with_embedder=False)
    missing = 0
    for name in args.name:
        row = index.get(name)
        if row is None:
            print(f"Unknown note: {name}")
            missing += 1
            continue
        if args.brief:
            body = " ".join(row["body"].split())
            if len(body) > BRIEF_CHARS:
                body = body[:BRIEF_CHARS].rstrip() + " […]"
            topics = ", ".join(json.loads(row["topics"]))
            print(f"# {row['name']}  [{row['type']}, {row['trust']}]  {row['title']}")
            if topics:
                print(f"topics: {topics}")
            print(body)
            print()
            continue
        path = Path(row["path"])
        print(path.read_text(encoding="utf-8") if path.exists() else row["body"])
    return 1 if missing else 0


def cmd_check(args: argparse.Namespace) -> int:
    roots = [r for r in notes_roots(args) if r.exists()]
    notes = load_notes(roots)
    names = {n.name for n in notes}
    report = []
    for note in notes:
        problems = note.problems()
        problems += [f"link to unknown note {link!r}" for link in note.links if link not in names]
        for problem in problems:
            report.append({"path": str(note.path), "problem": problem})
    seen: dict[str, Path] = {}
    for note in notes:
        if note.name in seen and note.path is not None:
            report.append(
                {"path": str(note.path), "problem": f"name {note.name!r} also in {seen[note.name]}"}
            )
        elif note.path is not None:
            seen[note.name] = note.path
    emit(
        args,
        report,
        "\n".join(f"{r['path']}: {r['problem']}" for r in report)
        or f"{len(notes)} notes, nothing to report.",
    )
    return 1 if report else 0


def cmd_stats(args: argparse.Namespace) -> int:
    index = open_index(args, with_embedder=False)
    stats = index.stats()
    emit(
        args,
        stats,
        "\n".join(f"{k}: {v}" for k, v in stats.items()),
    )
    return 0


def cmd_extract(args: argparse.Namespace) -> int:
    day = args.day or date.today() - timedelta(days=1)
    summary = extract_day(day, args.projects, args.out)
    data = {
        "day": day.isoformat(),
        "sessions": len(summary.sessions),
        "repos": len({s.repo for s in summary.sessions}),
        "raw_bytes": summary.raw_bytes,
        "written_bytes": summary.written_bytes,
        "out_dir": str(summary.out_dir),
    }
    emit(
        args,
        data,
        f"{data['sessions']} sessions in {data['repos']} repositories,"
        f" {summary.raw_bytes / 1e6:.1f} MB of transcripts kept as"
        f" {summary.written_bytes / 1e6:.2f} MB in {summary.out_dir}",
    )
    return 0


def cmd_curate(args: argparse.Namespace) -> int:
    from kb.curate import (
        DEFAULT_MAX_NEW,
        DEFAULT_MODEL,
        curate_day,
        curate_material,
        runner_from_env,
    )

    day = args.day or date.today() - timedelta(days=1)
    roots = notes_roots(args)
    notes_root = roots[0]
    model = args.model or os.environ.get("KB_CURATE_MODEL") or DEFAULT_MODEL
    try:
        runner = runner_from_env(model)
    except ValueError as exc:
        print(f"kb curate: {exc}", file=sys.stderr)
        return 2
    max_new = args.max_new or int(os.environ.get("KB_CURATE_MAX") or DEFAULT_MAX_NEW)
    readonly = [r for r in roots[1:] if r.is_dir()]
    if args.material:
        report = curate_material(
            args.name or args.material.stem,
            args.material.read_text(encoding="utf-8", errors="replace"),
            day,
            notes_root,
            runner,
            max_new=max_new,
            readonly_roots=readonly,
        )
    else:
        report = curate_day(
            day,
            notes_root,
            runner,
            transcripts_dir=args.transcripts,
            max_new=max_new,
            projects_dir=args.projects,
            readonly_roots=readonly,
        )
    data = {
        "day": day.isoformat(),
        "batches": report.batches,
        "proposals": report.proposals,
        "created": report.created,
        "merged": report.merged,
        "dropped": report.dropped,
        "errors": report.errors,
        "notes_root": str(notes_root),
    }
    emit(args, data, report.markdown().rstrip())
    return 1 if report.errors and not (report.created or report.merged) else 0


def cmd_serve(args: argparse.Namespace) -> int:
    from kb.server import Knowledge, clone_if_needed, serve, unlock

    token = os.environ.get("KB_TOKEN", "")
    if len(token) < 16:
        print("Set KB_TOKEN (16 characters or more): every request must carry it.")
        return 1
    if args.repo_dir and not (args.repo_dir / ".git").is_dir():
        repo = os.environ.get("KB_REPO", "")
        if not repo:
            print(f"{args.repo_dir} is not a git clone and KB_REPO is not set.")
            return 1
        clone_if_needed(args.repo_dir, repo, os.environ.get("KB_GITHUB_TOKEN"))
    if args.repo_dir:
        unlock(args.repo_dir, os.environ.get("KB_CRYPT_KEY"))
    db = args.db or Path(os.environ.get("KB_DB") or DEFAULT_DB)
    knowledge = Knowledge(db, get_embedder(args.embed), notes_roots(args), args.repo_dir)
    every = args.pull_every
    if every is None:
        every = float(os.environ.get("KB_PULL_SECONDS") or 300)
    serve(knowledge, token, args.host, args.port, every)
    return 0


if __name__ == "__main__":
    sys.exit(main())
