---
name: ci-review
description: Proposes and sets up an AI review step on a repo's CI that reviews every PR/MR and checks, from the proof the PR/MR carries (screenshots, videos, network captures, test report), that what was delivered and tested really works, so the team stops reviewing by hand. Use when the user says "AI review on CI", "agent review in the pipeline", "review every PR automatically", "claude -p in CI", "set up claude-code-action", or when working in a repo whose CI has no such step and no answer is recorded for it.
---

# AI review with proof on CI

The idea: every PR/MR carries its proof (what the test-evidence skill produces: screenshots, a short video, the requests behind it, a test report). An agent on the CI reads the diff, the code around it and the proof, checks the code itself rather than trusting the tests or the screenshots, challenges what doesn't hold, and posts its verdict on the PR/MR. People read the verdict instead of the whole diff.

Templates are in the `templates/` folder of this skill's base directory (`~/.claude/skills/ci-review/` when installed by install.sh; `$SK` below is that `templates/` folder). The review instructions live in one file, `review-prompt.md`, that any agent CLI can take, so the same step works with another agent (Codex and others) by swapping the command.

## 1. Propose it once per repo

Answers are kept in `~/.claude-sync/ai-review.md` when the sync engine is installed, otherwise `~/.claude/ai-review.md`: one line per repo, `<host>/<owner>/<repo> | yes / no / later | YYYY-MM-DD | note`.

When a repo we work on has no AI review step on its CI and no line in that file, propose it once, in a few lines: what it does, what it costs (one agent run per PR push), what the repo needs (a secret). Say what you'd pick for this repo and why. Record the answer, whatever it is, and don't ask again for that repo.

## 2. Pick the route with the user

Look at the CI first (`.github/workflows/`, `.gitlab-ci.yml`, `azure-pipelines.yml`), then recommend one:

| CI | Route | Auth |
|---|---|---|
| GitHub Actions | `anthropics/claude-code-action@v1` with the official code-review plugin (`$SK/templates/github-action.yml`) | `ANTHROPIC_API_KEY` secret, or Bedrock / Vertex through OIDC (`use_bedrock` / `use_vertex`) |
| GitHub Actions, proof check included | the CLI headless (`$SK/templates/github-cli.yml` + `review-prompt.md`) | `ANTHROPIC_API_KEY` secret; the job's `GITHUB_TOKEN` posts the comment |
| GitLab CI | the CLI headless (`$SK/templates/gitlab-ci.yml` + `review-prompt.md`), see code.claude.com/docs/en/gitlab-ci-cd (beta) | `ANTHROPIC_API_KEY` and a project access token `GITLAB_REVIEW_TOKEN` (api scope) as masked CI/CD variables |
| Azure Pipelines, others | the same CLI steps; no official guide, so test it on a throwaway branch first | the same key, plus a token that can comment on PRs |

The quickest GitHub setup is `/install-github-app` in an interactive session (repo admin and the `gh` CLI needed): it installs the GitHub App, stores the key as a secret and opens a PR with the workflow. Offer it when the user is at their terminal.

Never write a key into a file, a commit or the chat: the user adds secrets themselves in the CI settings, and you tell them the exact names.

## 3. Set it up

1. Copy the template into the repo and adapt it: branch filters, the review prompt's language (the repo's PR language), the CLI's `--max-turns`.
2. Keep `review-prompt.md` next to the workflow (`.github/ai-review/` or `ci/ai-review/`) and tune it to the project: what counts as proof here, which paths need extra care.
3. Open it as a PR (ask first, as for any PR). Its own run is the first test: check that the verdict comment appears and reads well. Permissions and comment posting are the part most likely to need a fix; read the job log if no comment shows up.
4. Record "yes" in the answers file, with the PR link.

## 4. What the review must say

The verdict, first line: works / doesn't work / can't tell (proof missing or doesn't match the change). "Works" needs both: the code does what the PR claims, read in context, and the proof shows it. Then, short: what the proof shows, what the code does that the proof and tests don't cover, tests that would still pass with the change reverted, and the risky spots. A PR without proof gets "can't tell" and a list of what to capture, not a guess.
