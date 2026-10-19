---
name: pr-watch
description: Tracks the pull requests the user and Claude worked on together until they are merged, and reports new comments, votes, CI results (green, failed) and status changes (merged, abandoned). Works with Azure DevOps and GitHub; the list follows the user on every computer through the config sync, never in the project repos. Use when the user says "watch this PR", "track the PR", "tell me when it's merged", "check the PRs", "any new comments on my PRs?", "stop watching", or right after you open or push a PR with the user.
---

# PR watch

A tracked PR is one JSON file in `~/.claude-sync/pr-watch/` (or `$PR_WATCH_DIR`): its URL, a note, and what was seen at the last check. The config sync carries the folder to every computer of the user; nothing is written in the project repos. Scripts are in `~/.claude/skills/pr-watch/` (`$SK` below).

```sh
bash $SK/pr-watch.sh add <PR URL> [--note "<what it is, what it waits for>"]
bash $SK/pr-watch.sh check            # what changed since the last check, then records it
bash $SK/pr-watch.sh check --peek     # same, without recording (the next check reports it again)
bash $SK/pr-watch.sh list
bash $SK/pr-watch.sh remove <PR URL>
```

`check` prints one line per change (new status, new vote, new comment with an excerpt and its file, a CI check that changed state with its link), or `No change.`. A PR that is merged, completed, abandoned or closed is reported once, then dropped. Comments by the person checking are not reported. `list` shows each PR's status and CI summary.

**CI**: on Azure DevOps, the PR's build and status policies (what the target branch requires; a PR stacked on another feature branch often has none: `no CI`); on GitHub, the check runs and commit statuses of the head commit. The summary (`CI green`, `CI running`, `CI failed`) follows the required checks; a failed optional one is named apart (`optional failed: …`). An expired build (Azure DevOps, after a push to the target branch) counts as failed: it must be queued again.

**Comment authors**, in `~/.claude-sync/pr-watch/config.json`; ask the user before adding one:

```json
{"bots": ["<display name or login>"], "ignoreAuthors": ["<display name or login>"]}
```

`bots`: still reported, marked `(bot)`; mention them to the user only when they raise a real problem. `ignoreAuthors`: never reported.

Auth: Azure DevOps uses `AZURE_DEVOPS_PAT` if set, otherwise the `az login` token; GitHub uses `GITHUB_TOKEN`, then `gh auth token`, then anonymous calls (public repos only). An error on one PR (signed out, no access) is printed apart and the others are still checked.

## When to track

- Right after you open a PR with the user, or push to one you prepared together: add it, with a note saying what it is and what it waits for (review, a PR it is stacked on, a deploy order), and tell the user in one line. Don't ask first: tracking only reads.
- When the user asks to watch a PR someone else opened, add it the same way.
- Then run `bash ~/.claude-sync/sync.sh now` so the other computers get it.

## Checking regularly

- **During the work day**: offer a recurring check in the current Claude Code session, with `CronCreate`, `durable: true` so it survives a restart, on weekdays during the user's hours, at an off minute (e.g. `17 8-18 * * 1-5`). Its prompt runs `check` and says what to do with the result (below). Say that the job lives in the project folder where it was created and expires after 7 days; offer to renew it when it does, while PRs are still tracked.
- **Every morning**, with no session open: the daily sync (daily-sync skill) runs `morning.sh`, which peeks and sends a desktop and phone notification through the reminders skill when something changed.
- **When the user asks** ("any news on my PRs?"): run `check`.

## What to do with a change

Start the message with what changed, PR by PR.

- **New comment**: read the whole thread (and the code it points at), say whether the reviewer is right, and propose the reply or the fix. Never post a reply, push a fix or resolve a thread without the user's yes.
- **Bot comment** `(bot)`: read it; bring it up only if it points at a real problem, with the fix you propose.
- **CI failed**: open the failing run (its link), read the failed step's errors (Azure DevOps: the build timeline's issues and logs, `az pipelines runs show` / the REST API; GitHub: `gh run view <id> --log-failed`), say why it failed and propose the fix. Expired: propose to queue it again. A failed optional check: mention it only if its findings matter.
- **CI green**: say so in one line, with what is left before the merge (votes, other policies).
- **Vote** (approved, approved with suggestions, waiting for author, rejected; on GitHub approved or changes requested): say it, and what is left before the merge (other reviewers, CI, policies). A rejection or "waiting for author" comes with the reviewer's comments: read them and propose the changes.
- **Vote reset or dismissed** (Azure DevOps can reset votes after a push; a GitHub review can be dismissed): say so, and that the reviewer has to approve again.
- **Merged**: say what it unblocks (a PR stacked on it to retarget, a deploy order, a ticket to move), and update the project notes if the repo keeps a list of open PRs.
- **Abandoned or closed**: ask whether the work moved elsewhere; if a new PR replaced it, add that one.
- `No change.`: one short line, nothing else.
