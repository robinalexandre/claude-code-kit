---
name: ci-review
description: Proposes and sets up AI code review on a repo's CI, the way the Claude Code team reviews its own PRs - finders then fresh verifiers so only confirmed findings are posted, Important / Nit / Pre-existing labels, a separate security pass, the change's risk deciding who must approve, a cap on review rounds - and checks, from the proof the PR/MR carries (screenshots, videos, network captures, test report), that what was delivered really works, so the team stops reviewing every diff by hand. Use when the user says "AI review on CI", "agent review in the pipeline", "review every PR automatically", "claude -p in CI", "set up claude-code-action", "security review on PRs", "REVIEW.md", or when working in a repo whose CI has no such step and no answer is recorded for it.
---

# AI review with proof on CI

The idea: every PR/MR carries its proof (what the test-evidence skill produces: screenshots, a short video, the requests behind it, a test report). Agents on the CI read the diff, the code around it and the proof, check the code itself rather than trusting the tests or the screenshots, and post a verdict on the PR/MR. People read the verdict and the few findings that survived verification instead of the whole diff.

It follows how the Claude Code team reviews its own code ("How the Claude Code team does code review", claude.dev blog, 2026-10-15): the least human review time that doesn't raise reverts or incidents, with every setting below chosen per repo.

Templates are in the `templates/` folder of this skill's base directory (`~/.claude/skills/ci-review/` when installed by install.sh; `$SK` below is that folder). The review instructions live in `review-prompt.md` (generic) and the repo's own `REVIEW.md` (its owners' rules); any agent CLI can take them, so the same steps work with another agent (Codex and others) by swapping the command.

## 1. Propose it once per repo

Answers are kept in `~/.claude-sync/ai-review.md` when the sync engine is installed, otherwise `~/.claude/ai-review.md`: one line per repo, `<host>/<owner>/<repo> | yes / no / later | YYYY-MM-DD | note` (with the settings chosen).

When a repo we work on has no AI review step on its CI and no line in that file, propose it once, in a few lines: what it does, what it costs (agent runs per PR push, more with depth), what the repo needs (a secret). Say what you'd pick for this repo and why. Record the answer, whatever it is, and don't ask again for that repo.

## 2. The process, layer by layer

1. **Before the PR**: the author's agent runs the tests, the build and the linter and shows their output, then reviews its own diff in a fresh context (`/code-review`, `/security-review` or a subagent). Say so in the repo's CLAUDE.md, short.
2. **Required CI**: lint, types, tests, build. Red blocks the merge.
3. **AI review on every push** (this skill's workflow): finders list candidate issues; a fresh reviewer (and in deep mode, voters first) checks each one in the code; only what holds, with a file and a line, is posted. Each finding is **Important** (blocks), **Nit** (at most 3) or **Pre-existing** (a bug the PR didn't introduce, never pinned on its author). Style, diagnostics and cleanups are dropped.
4. **Security review**, a separate pass whose findings block like any important one.
5. **Risk-based approval**: the change sets the risk, not its author. Low (docs, copy, tests, additive behind a flag), medium (ordinary product changes), high (data other clients read, migrations, rules, auth, payments, triggers, CI and release workflows, the repo's sensitive paths). A bot's approval never counts as a person's.
6. **Every finding is answered**: fixed (the next run marks it resolved) or its thread resolved by a person with a short reason. Branch protection can require it.
7. **Convergence**: after a few rounds, a PR the bot approved has only its new commits reviewed, from the commit its standing approval names (earlier findings are still checked); one it didn't approve gets the whole review again, so it can still be approved; past the cap, the review asks the author to step back and rethink the approach instead of patching one finding at a time; a bug that is one instance of a pattern is flagged as a class, so it is fixed everywhere at once.
8. **Learn from misses**: a review comment that comes back on several PRs moves into REVIEW.md; a bug that reached production becomes a line in REVIEW.md's "What failure looks like here".

## 3. Settings, per repo

Ask the user for each; recommend from the repo (what breaks there, how often it ships, who reviews today).

| Setting | Where | Choices |
|---|---|---|
| Depth | `REVIEW_DEPTH` in the workflow | `quick` (one pass), `standard` (a finder, the security finder when it's on, then a fresh verifier: 2 to 3× quick), `deep` (finders per concern, 2 voters, then the verifier: 5 to 6× quick). Each push is reviewed, so on a seat token (`CLAUDE_CODE_OAUTH_TOKEN`, shared 5-hour limit) start with `quick` and raise it where one missed bug costs more than the review. |
| Security pass | `SECURITY_REVIEW` | `true` adds a security finder to standard and deep (quick checks security in its one pass). With an Anthropic Console key, the official `anthropics/claude-code-security-review` action is an alternative (`$SK/templates/github-security-action.yml`); it takes only an API key and is not hardened against prompt injection, so run it on trusted PRs only. |
| Automatic approval | `APPROVE_UP_TO` | `none` (never), `low`, `medium`, `high`: the bot approves a "Works" up to that risk. Ask before turning it on. |
| Always high risk | `HIGH_RISK_PATHS` | An extended regex on file paths (rules, migrations, workflows), kept in step with REVIEW.md. |
| Rounds | `FULL_ROUNDS`, `MAX_ROUNDS` | Defaults 2 and 3, as the Claude Code team does. |
| Model | `MODEL` | Empty for the CLI's default, or a model id. |
| Proof policy | `REVIEW.md` | `required` (the team attaches proof, test-evidence) or `optional` (the verdict rests on the code and the tests). |
| Merge rules | repo admin, in branch protection | "Require conversation resolution before merging", "Dismiss stale approvals when new commits are pushed", required approvals (one more than the bot gives to keep a person on everything the bot doesn't approve), a CODEOWNERS file for the paths that always need a person. Optional: propose them, the user decides per repo. |

## 4. Pick the route with the user

Look at the CI first (`.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`), then recommend one:

| CI | Route | Auth |
|---|---|---|
| GitHub Actions | the CLI headless (`$SK/templates/github-cli.yml` + `review-prompt.md` + `REVIEW.md`): every setting above | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` secret; the job's `GITHUB_TOKEN` posts the review |
| GitHub, simplest | `anthropics/claude-code-action@v1` with the official code-review plugin (`$SK/templates/github-action.yml`); on a Team or Enterprise plan, the managed Code Review for Claude Code (code.claude.com/docs/en/code-review) does the same with Quick / Standard / Deep in its settings | `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`, or Bedrock / Vertex through OIDC |
| GitLab CI | the CLI headless (`$SK/templates/gitlab-ci.yml` + the same prompt files), one pass, see code.claude.com/docs/en/gitlab-ci-cd (beta) | `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`, and a project access token `GITLAB_REVIEW_TOKEN` (api scope), as masked CI/CD variables |
| Azure Pipelines, others | port the GitHub CLI workflow's steps (fetch, passes, post) to that CI's API; no official guide, so test it on a throwaway branch first | the same key or token, plus a token that can comment on PRs |

On GitHub, offer "@claude" in PR comments alongside the review (`$SK/templates/github-mention.yml`): people ask it to explain, re-check or push a fix to the PR branch. It needs the same secret and the Claude GitHub App installed on the repo (a repo admin, from github.com/apps/claude).

The quickest GitHub setup is `/install-github-app` in an interactive session (repo admin and the `gh` CLI needed): it installs the GitHub App, stores the key as a secret and opens a PR with the workflow. Offer it when the user is at their terminal.

**Which credential.** Every route takes either. A team on a Claude plan (Pro, Max, Team, Enterprise) can run the review on a seat: the seat holder runs `claude setup-token` and the repo admin stores the printed token as `CLAUDE_CODE_OAUTH_TOKEN`. It lasts a year, uses that person's plan limits (depth multiplies the runs), and stops when they lose the seat, so say whose seat it is and when it expires (a reminder a month before helps). An Anthropic Console key (`ANTHROPIC_API_KEY`) bills per token instead and suits a shared, long-lived setup; it wins when both are set. `--bare` (faster, ignores the repo's hooks and MCP servers) reads only `ANTHROPIC_API_KEY`: with a seat token, the CLI template drops it and deletes `.claude/` and `.mcp.json` from the checkout instead, since the PR branch could otherwise run its own hooks.

Never write a key into a file, a commit or the chat: the user adds secrets themselves in the CI settings, and you tell them the exact names. Only a repo admin can; when the user isn't one, name who has to do it.

## 5. Set it up

1. Copy the workflow template into the repo and set its settings (section 3) and branch filters.
2. Put `review-prompt.md` next to the workflow (`.github/ai-review/` or `ci/ai-review/`), unchanged: it is generic. Write the repo's `REVIEW.md` at its root from `$SK/templates/REVIEW.md` with the user: what failure looks like there, the paths that need care, what to skip, the proof policy. Move repo-specific lines an older review-prompt.md carried into it.
3. Add `$SK/templates/pull_request_template.md` as `.github/pull_request_template.md` (or merge its Testing, Risk and How to revert sections into the repo's own).
4. **Automatic approval** (GitHub CLI template): the job approves "Works" up to `APPROVE_UP_TO`, requests changes on "Doesn't work", withdraws its earlier review when that changes, keeps it when it holds, and never merges. The review lives in one comment per PR that every run edits; each line finding is a line comment the next run edits or marks resolved (and resolves its thread). A repo admin must tick Settings › Actions › General › "Allow GitHub Actions to create and approve pull requests"; until then GitHub refuses the approval and the comment says so. The template reads the prompt and REVIEW.md from the default branch, approves only PRs into it, pins the approval to the reviewed commit, and never approves a PR that changes `.github/`, `CLAUDE.md`, `CLAUDE.local.md`, `REVIEW.md`, `.claude/` or `.mcp.json`, so a PR can't rewrite the rules it is judged by.
5. Open it as a PR (ask first, as for any PR). Its own run is the first test: check that the verdict comment and the line comments appear and read well. Permissions and comment posting are the part most likely to need a fix; read the job log if nothing shows up.
6. Record "yes" in the answers file, with the settings and the PR link.

## 6. What the review says

First line, the verdict: works / doesn't work / can't tell. "Works" needs no important finding left, the code doing what the PR claims, read in context; under the `required` proof policy the proof must show it too. Second line, the count first ("2 important, 1 nit, 1 pre-existing", or "Nothing to fix.") and the risk with its reason. Then, short: what was checked, what the tests (and the proof) don't cover, tests that should exist. Line findings carry their label, their evidence and the fix (a one-click suggestion when it fits one line). The CLI templates ask for all of it as structured output (`--json-schema`), so the pipeline reads it instead of parsing the comment, and enforces the rules itself: an important finding blocks whatever the verdict line says, nits are capped at 3, `HIGH_RISK_PATHS` force high risk.
