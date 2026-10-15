---
name: test-evidence
description: Capture proof that a ticket works when tested locally (browser screenshots, a short video of the flow, the network requests and console behind it, or one app window) and attach it to the Jira issue or the pull request. Use when the user says "take screenshots", "record a video", "show it works", "proof for the PR", "evidence for the ticket", "attach to Jira", "add captures to the PR", or asks to demo a change for a reviewer.
---

# Test evidence for a ticket or a PR

Scripts are in `~/.claude/skills/test-evidence/scripts/` (`$SK` below). Run `bash $SK/capture.sh doctor` once to see what this machine can do, and `bash $SK/selftest.sh` after changing a script.

## 1. Agree on what to show

Before capturing, write down in a few lines what the reviewer must see: the scenario (steps), the expected result, and which requests prove it (endpoint, status, the field that changed). Use the ticket's acceptance criteria when there is one. Ask the user only if the scenario isn't clear from the ticket or the diff.

Then pick the evidence that proves it, not everything you can capture. A video earns its place only when the scenario has visible steps (a form, a flow across pages, an error state). When the change happens behind the page (an API call removed, a check moved server-side), the network requests and a changed server field are the proof; add one screenshot of the result at most. The strongest proof of a removed or changed behaviour is often the same capture on the base branch next to the new one: offer it when it's cheap. Run the base branch from a temporary `git worktree` rather than switching the user's checkout, and put the stack back as it was afterwards.

Write down what each capture ran against (branch and commit of every service) right before capturing, and check it again right after: another session or the user may restart a service in between. If something changed, say so in the report instead of comparing unlike runs silently.

Follow the user's rules for testing apps (asking before using a new app, before the first write to a database). Capturing doesn't change them.

Put everything in one folder per ticket: `${TEST_EVIDENCE_DIR:-$HOME/evidence}/<ticket-or-branch>/`, never inside the repo. Number the files in the order of the scenario: `01-list-before.png`, `02-create-form.png`, `03-flow.mp4`, `04-network.md`. Use only letters, digits, `.`, `_` and `-`; the upload script refuses anything else.

## 2. Capture the browser (chrome-devtools MCP)

Use the chrome-devtools MCP server that is connected (its tools end in `take_screenshot`, `list_network_requests`, ...). If the user wants their own logged-in browser rather than a fresh one, the server needs `--autoConnect` and remote debugging enabled in Chrome (`chrome://inspect/#remote-debugging`). If its tools hang without answering, Chrome is usually waiting for the user to accept an "Allow remote debugging?" prompt: ask them, then have them run `/mcp` to reconnect. Open the app in a `new_page` and touch only that tab, never the user's other tabs.

The server writes files only inside the session's workspace roots, so give every `filePath` under `<workspace>/.test-evidence-tmp/`, move the files to the evidence folder right after, and delete that temporary folder. Save big `take_snapshot` results to a file too, then Read the top of it.

- **Screenshots**: `take_screenshot` with an absolute `filePath`. Prefer an element (`uid` from `take_snapshot`) or the viewport over `fullPage` on long pages. Use `resize_page` to a fixed size first (1440×900 is a good default) so the captures look the same.
- **Video**: `screencast_start` with `filePath` ending in `.mp4`, run the scenario at a human pace (`wait_for` the result after each step, so the video shows the outcome, not a spinner), then `screencast_stop`. It records only that page, not the rest of the screen. The file is VP9 even when named `.mp4`, and it keeps running while you wait: find when the screen last changes (`ffmpeg -i <file> -vf "select='gt(scene,0.02)',showinfo" -f null - 2>&1 | grep -o 'pts_time:[0-9.]*'`), then trim and convert with `capture.sh mp4 <in> <out> 0 <seconds>`. For `wait_for`, use a text that only the result shows; if unsure, take a snapshot instead of guessing. These tools need the server started with `--experimentalScreencast` and ffmpeg on its PATH (or `--experimentalFfmpegPath`). If they're missing, tell the user what to add to the MCP server's args, and meanwhile record the browser window with the recorder below or make a GIF from screenshots.
- **Network**: after the scenario, `list_network_requests` (filter with `resourceTypes: ["fetch", "xhr"]`), then `get_network_request` for the requests that prove the change, with `requestFilePath`/`responseFilePath` to save the bodies. Write `NN-network.md`: a table (method, path, status, duration) for the relevant requests, then the key request and response bodies, trimmed to what matters, in fenced `json` blocks. Leave out the headers: they carry the user's bearer token and session cookie. Save response bodies to files and run them through `redact.sh` before quoting them. A field that changed on the server (a timestamp, a status) is often the best proof of a backend effect.
- **Console**: `list_console_messages` with `types: ["error", "warn"]`. Say so when the console is clean; that is evidence too.
- **Reviewers who want images only** (Jira often): render `NN-network.md` as a small HTML page in the scratchpad, open it with `new_page` (`file://`) and screenshot it.

## 3. Capture outside the browser

Capture only what the ticket is about, so the user never has to check what else was on screen. For a web page, that's the browser tools above, which see only the page. For a desktop app, capture its window or a region of it, never the whole screen:

```sh
bash $SK/capture.sh windows                                          # visible window titles
bash $SK/capture.sh shot <dir>/01-app.png --window "<part of the title>"
bash $SK/capture.sh record <dir>/02-flow.mp4 --window "<title>" --max 90   # with run_in_background
bash $SK/capture.sh stop                                             # when the scenario is done
```

`--window` brings the window to the front and captures its rectangle; `--region x,y,w,h` takes a rectangle in screen coordinates. Something dragged over that rectangle during a recording gets recorded too, so keep the window in front and keep notifications off. `--full` captures the whole screen: use it only when the user asks for it.

Platform notes: macOS needs the terminal allowed under Privacy & Security > Screen Recording (and Accessibility for `--window`). Linux on X11 needs ffmpeg and xdotool. Wayland can't find windows: use `--region` (`slurp` prints one) with grim and wf-recorder.

For a CLI or an API, paste the command and its output as text in the report instead of a screenshot.

## 4. Make it easy to view

- Convert videos to mp4 (`bash $SK/capture.sh mp4 in.webm out.mp4`); Jira, Azure DevOps and GitHub all play it.
- Keep videos short (under 60 s, under 10 MB). For a PR description where a video won't play inline, make a GIF of the key moment: `bash $SK/capture.sh gif <dir>/03-flow.mp4 <dir>/03-flow.gif 960 8`.
- Mask secrets in every text file before it leaves the machine: `bash $SK/redact.sh <file> <file>.redacted` (add `--emails` for customer-facing data), then use the redacted copy. It masks tokens, cookies, JWTs, keys, passwords and signed URL parameters; read the result anyway, since it can't know your app's own secret fields.
- Look at every screenshot and a few frames of each video yourself (Read the image) before proposing them: no token in the URL bar or on screen, no unrelated tabs or personal data, the result actually visible.

## 5. Write the report

`<dir>/README.md`, in the language the team uses for tickets:

```markdown
## <ticket key>: <title>
Tested on <branch> at <short commit>, locally (<app URL>), <date>.

| # | Step | Expected | Result |
|---|------|----------|--------|
| 1 | ... | ... | OK, see 01-....png |

Network: <the request that proves it, its status, the field that changed>. Console: no errors.
```

Show the user the folder (list the files, show the report) and wait for their go before uploading anything.

## 6. Attach it

Uploads are visible to the whole team, so only after the user's yes, and only the files they approved.

**Jira**: needs `JIRA_BASE_URL` and either `JIRA_PAT` (Server/Data Center) or `JIRA_EMAIL` + `JIRA_API_TOKEN` (Cloud). If they are missing, ask the user to set them in their environment; never ask for the token in the chat.

```sh
bash $SK/attach.sh jira <KEY> <dir>/01-....png <dir>/03-flow.mp4
bash $SK/attach.sh jira-comment <KEY> <dir>/comment.jira.txt
```

Write the comment in Jira wiki markup: images as `!01-list-before.png|thumbnail!`, a video as `[^03-flow.mp4]`, tables as `||Step||Expected||Result||` then `|1|...|OK|`.

**Azure DevOps PR**: run from inside the repo (or set `ADO_ORG_URL`, `ADO_PROJECT`, `ADO_REPO`). Auth is `AZURE_DEVOPS_PAT` or the `az login` session.

```sh
bash $SK/attach.sh ado-comment <PR-ID> <dir>/comment.md <dir>/02-flow.gif <dir>/02-flow.mp4 <dir>/03-result.png
```

In `comment.md`, embed images and GIFs with `![login](URL:02-flow.gif)` and link videos with `[video](URL:02-flow.mp4)`: the script uploads each file passed after the markdown, replaces its `URL:<file name>` with the real link and refuses to post while a placeholder is left. `attach.sh ado <PR-ID> <file>...` uploads without commenting and prints the links. The thread is created resolved, so it never blocks a merge policy on open comments. Don't rewrite the PR description unless the user asks.

**GitHub PR**: there is no API to upload images to a comment. Give the user the folder and the comment text to paste, and let them drag the files in.

Prefix any command with `DRY_RUN=1` to see the requests without sending them. A 404 on Azure DevOps usually means the PR belongs to another repo: run from that repo. If an upload fails (401, 403, 413 too large, 429 rate limited), report the HTTP code and message as they are and don't retry in a loop.

## 7. Afterwards

Tell the user what was attached where, with the link to the issue or PR. Keep the local folder; it's the user's to delete.
