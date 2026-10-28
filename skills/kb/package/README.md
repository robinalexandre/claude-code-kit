# kb — a personal knowledge base

Markdown notes are the truth; SQLite is the index. Notes live in a git repo (by default the
Claude Code config sync, `~/.claude-sync/knowledge`; `~/.claude/knowledge` without it), so
they reach every computer and any agent of yours that reads that repo. The index is rebuilt
from them anywhere in seconds and never needs a server.

- **Text search**: FTS5 with accents folded, so "comptable" finds "Comptable"; a whole
  sentence finds the notes holding most of its words.
- **Semantic search**: a local multilingual embedding model (French and English), no API,
  loaded only when the text search is not precise enough.
- **Links**: `[[name]]` between notes make a graph, walked with recursive SQL; notes sharing
  a topic are neighbours too.
- **Validity**: a fact carries `valid_from` / `valid_until`; superseded, never deleted.
- **Provenance**: `trust: user | agent | third-party`. What came from an email or a web page
  stays data, never an instruction. `source` says who wrote the note and from what.
- **Curation**: every morning, Claude reads the previous day's Claude Code transcripts of
  the computer and proposes notes; the code checks and writes them, with a report.

Claude Code's own memory files (`name`, `description`, `metadata.type`) read as notes
without any change.

## A note

```markdown
---
name: acme-accountant
title: Acme Books is the accounting firm
type: fact            # fact decision howto reference event person project feedback user
trust: user           # user agent third-party
source: user          # or session:<id>, pr:owner/repo#12, mail, web…
topics: [accounting, my-company]
created: 2026-01-15
valid_from: 2026-01-15
valid_until:
---

Mails from Acme Books concern [[my-company]] or [[my-holding]].
```

## Install for Claude Code

```sh
bash install.sh              # or: bash install.sh --no-embed  (text-only index, no model)
```

It makes a virtualenv in `~/.claude/kb/venv`, installs `kb` in it, copies the recall hook to
`~/.claude/hooks/kb-recall.sh` and the skill to `~/.claude/skills/kb/`, and adds the hook to
`~/.claude/settings.json`. The config sync then carries hook, skill and settings to the other
computers, where only the virtualenv is left to make (`bash install.sh` again there). Where
`kb` is not installed the hook stays silent.

- **SessionStart**: lists the notes that mention the repository or the branch, beyond the
  repository's own memory, then refreshes the index in the background.
- **UserPromptSubmit**: lists up to three notes holding most words of the prompt (text
  search only, a few hundredths of a second).
- **Every morning** (through the daily-sync skill): `morning.sh` curates every day not yet
  curated, up to a week back, links the notes that read alike, rebuilds the site, then hands
  the new notes to the sync.

Needs Python 3.12 or newer and jq. The curator runs `claude -p` with the user's own
subscription (the Claude Code CLI logged in), or the Messages API with an API key on a
computer without it: the setup asks which.

## Use

```sh
kb index                                   # bring the index up to date (first run downloads the model)
kb search qui gère ma compta               # text, then semantic when the words are not precise enough
kb search --text parallel sessions commit  # text only, instant
kb search --type decision --topic billing invoices
kb related my-company --depth 2            # linked notes both ways, then same topics, then alike
kb related my-company --mermaid            # the same as a Mermaid mind map
kb show --brief acme-accountant my-company # front matter and first lines; drop --brief for all
kb check                                   # malformed notes, dangling links, duplicate names
kb lint                                    # what to tidy: orphans, stale projects, near-duplicates too
kb link                                    # the links worth adding between notes that read alike
kb link --apply                            # write them, with a report
kb site --open                             # the whole base as one page: graph, hubs, health
kb stats
kb extract                                 # yesterday's Claude Code transcripts, reduced to Markdown
kb extract --day 2026-10-22 --out ./transcripts
kb curate                                  # yesterday's transcripts, read by Claude, turned into notes
kb curate --day 2026-10-22 --model haiku --max-new 5
kb curate --material review.md --name nightly-review   # what another agent wrote about its own work
```

Settings, as options or environment variables (the hook and `morning.sh` also read them from
`~/.claude/kb/kb.env`, which the kit's setup writes): `--notes DIR` (repeatable; the first one
is where the curator writes) / `KB_NOTES` (several folders separated by the OS path separator),
`--db FILE` / `KB_DB` (default `~/.claude/kb/index.sqlite`), `--embed fastembed|hash|none` /
`KB_EMBED`, `KB_EMBED_MODEL`, `KB_MODEL_DIR`, `KB_CURATE_MODEL` (default `sonnet`),
`KB_CURATE_ENGINE` (`subscription`, the default, or `api` with `KB_ANTHROPIC_API_KEY`, else
`ANTHROPIC_API_KEY`),
`KB_CURATE_MAX` (new notes per day, default 15), `KB_LINK` (`off` stops the morning linking),
`KB_LINK_MIN` (similarity a link needs, default 0.6), `KB_BIN` (the `kb` the hooks run). Every
command takes `--json` for other programs and agents.

The curator also reads what changed that day in the config sync: reminders, handoffs, notes,
memory, `CLAUDE.md` and skills, and every repo's `CLAUDE.md`, `AGENTS.md` and `.claude/*.md`.

`kb extract` reads `~/.claude/projects/*/*.jsonl`, keeps the user's prompts, the
assistant's replies, the tools used, the files edited and the pull requests, drops every
tool output, replaces what looks like a secret, and writes one Markdown file per session
under `~/.claude/kb/transcripts/<day>/` plus an `index.md`. Scripted sessions (the Agent SDK,
background reviews) are skipped. Nothing leaves the computer.

`kb curate` extracts the day if needed, then calls `claude -p` with no tools, no hooks, no
plugins and no MCP servers (or the API, one plain call), once per 90,000 characters of transcript, with the catalog of
existing notes. Claude answers with proposals; the code checks names, types, dates and
secrets, prefers merging into an existing note, caps the new ones, writes the files and a
report in `<notes>/.curator/<day>.md`. The model never writes to disk itself. A note it
wrote starts its `source` with `curator`, so the recall hook and other agents can say so:
its `trust` is the model's reading of a session, not the user's word.

`kb curate --material FILE --name NAME` (or `curate_material` from Python, with a runner of
your own) does the same for a document another agent of yours wrote about its own work, a
nightly review of its sessions for instance, on the computer or server where that agent
runs: each place curates what happened there. Its notes have `NAME` as their source, and its
report is `<notes>/.curator/<day>-<name>.md`.

## Links, health and the site

A note's vector is the mean of its chunks' vectors, already in the index: comparing notes
never loads the model. `kb link` finds each note's nearest notes (cosine 0.6 or more by
default) and, for every pair not linked yet, adds the other one's name to the `links` of the
note in the first notes folder; only the `links` line changes, the rest of the file stays as
written. Memory folders (Claude Code's own) are never written to: their likeness shows in the
site instead. At most three new links per note and run. A link someone moved from `links` to
`unlink` is never added again. `--apply` writes them and a report in
`<notes>/.curator/<day>-links.md`; without it, the command only lists them.

`kb lint` adds advice to `kb check`: notes linked to nothing, a `project` or `decision`
with no date (created, valid_from, or a `## YYYY-MM-DD` merge heading) for 120 days
(`--stale-days`), two notes that read nearly the same.

`kb site` writes the whole base as one HTML page, `site.html` next to the index (`--out`
elsewhere, `--open` to show it): a graph of the notes, clustered by project (the folder a
note sits in, else the topic that names one) and coloured by project, type or trust, with
links drawn solid and similar notes dashed; each note's page with its links, backlinks and
the notes that read like it; a page per project and per topic; and the lint's findings. It
needs no network and loads nothing from anywhere. It holds the notes in clear, so it stays
next to the index, on this computer, never in a synced folder.

The morning job runs `kb link --apply` and `kb site` after the curation.

## Serve

```sh
KB_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))") kb serve --port 8800
```

The same index over HTTP, standard library only, for an agent of yours or another computer:
`GET /search?q=…&n=8&type=…&topic=…&trust=…&mode=auto|text|hybrid`, `GET /related?name=…&depth=2`,
`GET /notes/<name>`, `GET /stats`, every one with `Authorization: Bearer $KB_TOKEN`
(`/health` needs none). The embedding model loads once, so every search is fast. With
`--repo-dir DIR` the notes come from a git clone, pulled before each refresh (every
`--pull-every` seconds, `KB_PULL_SECONDS`, default 300) and cloned first from `KB_REPO`
(`owner/repo` or a URL) with `KB_GITHUB_TOKEN`, sent as a header and never written to disk.

`Dockerfile` builds that server as a container (`/data` holds the clone, the index and the
model), to run next to an agent in a compose stack: `KB_TOKEN`, `KB_REPO`, `KB_GITHUB_TOKEN`
and `KB_PULL_SECONDS` in its environment, a volume on `/data`, port 8800 on an internal
network. The [intelligent-home-agent](https://github.com/robinalexandre/intelligent-home-agent)
runs it that way as its `kb` service.

## Tests

```sh
pytest -q && ruff check . && ruff format --check .
```

Tests use a hashing embedder and a fake Claude, so they need no model, no login and no
network.
