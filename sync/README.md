# Claude Code config sync

Keeps your global Claude Code config the same on every computer through a private git repo of your own (GitHub, GitLab, Azure DevOps, any host), and carries handoff notes between them. macOS, Linux and Windows (Git Bash).

## What syncs

| Synced | Where it lives locally |
|---|---|
| `CLAUDE.md`, hooks, mods, skills, status line (and agents, commands, output styles, keybindings, the reminders' phone setting) | `~/.claude/` |
| Settings, including the plugins and marketplaces you enabled | `~/.claude/settings.json`, built from `settings.shared.json` + `machines/<machine>.json` |
| MCP servers added for all projects (`claude mcp add -s user`), without their secrets | `~/.claude.json`, one file per server in `mcp/` |
| Agent config that no repo's git tracks: `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.mcp.json`, everything in `.claude/` (except `worktrees/`), nested `CLAUDE.md` and `AGENTS.md`, and a project's own MCP servers | each repo in the dev folder, stored in `repos/<host>/<owner>/<name>/`; the dev folder itself and its folders that aren't repos, stored in `folders/` |
| Memory of the dev folder | `~/.claude/projects/<dev folder>/memory/` |
| Memory of each repo and folder in the dev folder | `~/.claude/projects/<repo or folder>/memory/`, stored in `memory-repos/<host>/<owner>/<name>/` and `memory-folders/<path>/` |
| Handoff notes | `~/.claude-sync/handoffs/` |

Not synced: sessions, history, credentials and login, claude.ai connectors and skills (`skills/synced`), repos outside the dev folder, and anything a repo tracks itself (that travels with the repo).

**Plugins:** the plugins you installed, the marketplaces they come from and their options all live in `settings.json`, so they sync with it; Claude Code installs the plugins enabled there by itself, in the background after a session starts. So a plugin installed on one computer shows up on the others, set up the same way, at their next session. Options marked sensitive stay in each computer's secure storage. A [claude-code-kit](../README.md) part whose setup is shared (the status line, the email rules, pr-watch's config, the phone for reminders, the chrome-devtools MCP) isn't asked again on the next computer; only what lives on one computer is: the morning schedule, the `~/.zshrc` line, git's hooks.

**MCP servers:** keys and tokens stay on each computer. In `mcp/`, every header value, every env value whose name looks like a secret (key, token, password, auth…), every `--token`-style argument and every `?api_key=`-style URL parameter is replaced by `__SECRET__`. A server that comes from another computer arrives with `__SECRET__` in those places and won't connect until you set the real value on this computer (ask Claude "set the <server> MCP key"). Your own values are kept when the server is later updated from another computer, unless its host or command changed: a key is never sent to a new address. Deleting a server takes it out of `mcp/`, but the other computers keep their copy until you delete it there too.

**Repos and folders:** a repo is recognized by its `origin` URL and its first commit, so it doesn't matter where each computer cloned it, and a different repo with the same URL gets nothing. A repo cloned later gets its config at the next sync; a folder's files arrive once that folder exists. Worktrees are skipped, and so is a file once the repo itself tracks it. Edits to a tracked file that aren't committed yet don't sync: commit and push them, or write a handoff. Repos and folders are checked at most every 2 minutes, and at every session start. Secrets in these files, JSON or text (tokens, `Bearer …`, `password=…`, passwords in URLs), are replaced by `__SECRET__` the same way. The computer they came from keeps its real values when the file is later updated from another computer; if another computer edited the very line that holds a secret, the file is kept apart (see below) rather than lose it. If it removed or rewrote that line, the new version is applied, and the previous copy goes to `.state/trash/` with a warning. Only a private key block, or a file over 1 MB, stays on its computer.

A repo's or folder's memory (the one Claude keeps for sessions started there) follows the same rules: it lands in the memory of the same repo, wherever it's cloned, or of the same folder, once Claude Code knows that folder on the computer it comes from (`~/.claude.json` lists every folder a session ran in).

When the same non-JSON file (a `CLAUDE.md`, a memory, a skill…) differs on two computers the first time they meet, or was edited on both before syncing, neither copy is overwritten: the session-start warning lists it, and it stays out of the sync until you delete one of the two copies (the other one then wins) or make them match.

**Merging:** JSON files merge by key and by list item (`json-merge.sh`), so commands approved on two computers at the same time all end up on both. When both changed the same value, the last one to sync wins.

## How it works

Hooks in the shared settings run `sync.sh`:

- **Session start:** shows open handoff notes from the other computers, then syncs in the background. `sync.sh fresh` lets a skill wait for that sync in the background (the reminders skill does).
- **Every morning** (with the [daily-sync](../skills/daily-sync/SKILL.md) skill): `sync.sh morning` syncs, then runs each `~/.claude/skills/*/morning.sh` (the [reminders](../skills/reminders/SKILL.md) skill notifies the day's reminders).
- **After each reply and at session end:** copies local changes into the repo, commits, pulls with a rebase, applies what came from the other computers, pushes. All in the background.
- **While a session is open** (with the [reminders-handoffs](../mods/reminders-handoffs) mod): `sync.sh poll` asks the remote whether `main` moved, every minute while its pane is open and every five minutes otherwise (one `git ls-remote`, any host; one check per computer however many sessions are open). It syncs only when another computer pushed, with a light pull: the repo scan and the MCP servers run again only when what came in touches them. Every session on the computer sees the new head and reads again, so a reminder or a handoff written elsewhere shows within a minute.

A change shows up on the other computer in its next session. A session that is already open keeps the `CLAUDE.md` it started with.

A change made straight in the sync repo (a skill renamed in `claude/`, a memory edited in `memory/`) works too: before copying anything from `~/.claude`, each run first puts on the computer what changed in the repo since its last good run, so the change is never undone. Files it removes go to `.state/trash/` for 30 days. If the same file also changed in `~/.claude`, the computer's version wins and the session start warns about it. A JSON file that holds the same content written another way (spacing, line breaks) counts as unchanged, so two computers don't keep pushing their own formatting back.

Safety checks: secrets are replaced by `__SECRET__` in every synced file and each computer keeps its own values; a file that may hold one but can't be redacted (binary, not UTF-8, a private key) stays on its computer; each commit is checked once more for known token formats; more than 10 files deleted at once in `~/.claude` stops the sync (deletions that come from the repo's history are applied), and a conflict (the same line of a non-JSON file changed on both sides) stops it too. Every stop shows up as a warning at the next session start, and Claude can fix it.

## Install

Needs Git, jq and Claude Code.

**The easy way:** install the `config-sync` plugin of [claude-code-kit](../README.md) on each computer (`/plugin install config-sync@claude-code-kit`; handoff, daily-sync and reminders bring it too). At the first session it offers its setup: it asks for the clone URL of an empty private repo on any git host (or creates one on GitHub with `gh`), clones it to `~/.claude-sync`, puts the engine in it on the first computer and runs the install below. Its later versions update the engine in your repo, which the sync then carries to your other computers; once you change an engine file there yourself, it tells you about new versions instead. `kit-engine.json` in the repo records what it put there. The kit's installer runs the same setup: `./install.sh config-sync` (or pick handoff, daily-sync or reminders), or `bash sync/setup.sh` from a clone of the kit.

**By hand:**

1. Create an empty **private** repo on any git host (GitHub, GitLab, Azure DevOps...), for example `claude-config`. The examples below use GitHub's URL; use your host's.
2. On your first computer, clone it to `~/.claude-sync`, copy this folder into it and run the install:

   ```sh
   git clone https://github.com/<you>/claude-config.git ~/.claude-sync
   cp -R claude-code-kit/sync/. ~/.claude-sync/
   ~/.claude-sync/install.sh            # or: install.sh <machine-name> [dev-folder]
   ```

   It asks for a name for this computer (`home-mac`, `work-pc`…: it must differ from your other computers', and a name another computer already reported is refused), a git name and email for the sync's commits and for the folder that holds your git repos, adds the sync hooks to `~/.claude/settings.json` (the previous file is kept as `settings.json.before-sync`), then saves this computer's config in the repo and pushes it.
3. On each other computer, clone the repo (it now holds the sync too) and run the install:

   **macOS / Linux**

   ```sh
   git clone https://github.com/<you>/claude-config.git ~/.claude-sync
   ~/.claude-sync/install.sh
   ```

   **Windows** (PowerShell)

   ```powershell
   git clone https://github.com/<you>/claude-config.git $HOME\.claude-sync
   powershell -ExecutionPolicy Bypass -File $HOME\.claude-sync\install.ps1
   ```

   It backs up the current files (`~/.claude.json` and the agent files of the repos and folders too) to `~/.claude/backups/before-sync-<date>/`, copies the synced config in, adds the shared MCP servers, and creates `machines/<name>.json` if the name is new. MCP servers and repo settings already on that computer are kept and shared with the others.

Then open a new Claude Code session.

On a work computer with a GitHub repo, sign in with a [fine-grained token](https://github.com/settings/personal-access-tokens/new) limited to this repo (Contents: read and write) rather than your whole account.

## Per-computer settings

`machines/<name>.json`:

```json
{
  "devDir": "~/dev",
  "exclude": ["skills/video-montage"],
  "mcpExclude": ["some-server"],
  "settings": { "remoteControlAtStartup": true }
}
```

- `devDir`: the folder that holds your git repos, where you start Claude. Its memory syncs, and so does the local config of every repo in it (up to 4 levels down).
- `exclude`: paths under `~/.claude` this computer doesn't get.
- `mcpExclude`: MCP servers this computer neither gets nor shares.
- `settings`: merged over `settings.shared.json`: values replace the shared ones, lists are added.

Edits to `~/.claude/settings.json` (from `/config`, permission prompts, by hand) are saved to `settings.shared.json`, so they reach every computer. To keep one on a single computer, move it to that computer's file. Paths under the home folder are stored as `__HOME__`.

## What each computer runs

Every sync (at most every 30 minutes) writes `inventory/<computer>.json` in the repo: the system and its version, the architecture, Claude Code, git, node, jq, gh, python and bash versions, the plugins and mods installed with their versions, each kit cloned in the dev folder (any repo with a `.claude-plugin/marketplace.json` or a kit's `parts.json`: branch, last commit, how far from its upstream, files changed) and the last sync commit. It also holds the [claude-code-kit](../README.md) parts the installer put there and the answers that computer gave the kit's questions (never a secret), so a new computer can be set up like it. So any computer can tell what the others run and when each last synced:

```sh
bash ~/.claude-sync/inventory.sh show    # one block per computer, then what differs between them
bash ~/.claude-sync/inventory.sh json    # the same, as JSON
```

Nothing in it is a secret, but it names your computers and folders: it stays in your private repo.

## When a sync fails

On every computer, the next session starts with the last sync error, if there was one. On Windows, Git Bash sometimes fails to start a process (`fatal error - add_item ... failed`), and that can stop a sync halfway or before it begins. So there a failed sync is tried twice more, 5 then 10 seconds later, and the next sync after every reply is one more try. If every try fails, or no background sync has finished for 15 minutes, you see one message in the session right after Claude's reply. You see it again only if the problem changes. `SYNC_RETRIES=<n>` sets how many times a failed sync is tried again on any system (`0` turns it off).

## Encrypted folders

The repo is private, but its personal folders (your memory, your knowledge notes, an assistant's files) are readable by anyone who gets into your git account. `sync.sh crypt` encrypts them with [git-crypt](https://github.com/AGWA/git-crypt): a git filter that encrypts at commit and decrypts at checkout, with a key that never goes in the repo. On your disk and for Claude nothing changes; on the host those files are ciphertext.

```sh
brew install git-crypt            # apt install git-crypt; Windows: scoop install git-crypt, or a release from github.com/AGWA/git-crypt
bash ~/.claude-sync/sync.sh crypt on memory memory-repos memory-folders knowledge
bash ~/.claude-sync/sync.sh crypt export ~/claude-sync.key    # keep it in your password manager, never in the repo
bash ~/.claude-sync/sync.sh crypt unlock ~/claude-sync.key    # once, on each other computer
bash ~/.claude-sync/sync.sh crypt status
```

The config-sync setup offers it on the first computer, and asks for the key file on the next ones. The encrypted folders are listed at the end of `.gitattributes`, after a marker line the engine's updates keep. A computer without the key (or without git-crypt) is *locked*: it sees ciphertext there, so the sync leaves those folders alone (nothing applied to `~/.claude`, nothing added from there, which git would commit in clear) and the session starts with a line saying so. A file that holds ciphertext instead of its content (an older engine wrote it in your memory, or git-crypt's checkout stopped partway) is never shared nor committed, which would encrypt it twice, and gets its clear version back once the computer is unlocked. Earlier commits still hold the files in clear: rewrite the history if that matters to you. A program that reads the repo through the host's API (not through git) has to encrypt and decrypt the format itself; the key file gives it everything it needs.

## Handoff

Install the `handoff` skill from this kit (`skills/handoff`). At the end of a session: "write a handoff". On the other computer: "pick up the handoff".

## Commands

```sh
bash ~/.claude-sync/sync.sh now      # sync right away
bash ~/.claude-sync/sync.sh status   # computer, last commit, last error, encryption, log
bash ~/.claude-sync/sync.sh crypt    # encrypted folders: status | on <folder>… | export <key file> | unlock <key file>
bash ~/.claude-sync/inventory.sh show   # what every computer runs
```
