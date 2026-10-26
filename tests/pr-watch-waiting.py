"""pr-watch's `waiting_for`: what a PR waits for next, from its votes, CI and conflicts. An expired build
(the target branch moved) only asks the user to queue it again once the PR is approved.

    python tests/pr-watch-waiting.py [skills/pr-watch]
"""

from __future__ import annotations

import importlib.util
import os
import sys
import tempfile

from pathlib import Path


def check_run(state: str, required: bool = True) -> dict:
    return {"state": state, "required": required}


def seen(checks: dict, votes: dict | None = None, conflicts: bool = False, target: str = "develop") -> dict:
    return {"status": "active", "checks": checks, "votes": votes or {}, "conflicts": conflicts, "target": target}


def main() -> int:
    skill = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "skills" / "pr-watch")
    root = Path(tempfile.mkdtemp())
    os.environ.update({"PR_WATCH_DIR": str(root / "pr-watch"), "PR_WATCH_SHARED": "off",
                       "XDG_CACHE_HOME": str(root / "cache"), "CLAUDE_CONFIG_DIR": str(root / "claude")})
    spec = importlib.util.spec_from_file_location("pr_watch", skill / "pr_watch.py")
    pr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pr)
    failures: list[str] = []

    def expect(what: str, got: str, wanted: str) -> None:
        print(f"{'ok  ' if got == wanted else 'FAIL'} {what}: {got}")
        if got != wanted:
            failures.append(what)

    approved = {"Ada": "approved"}
    expired = {"gate": check_run("expired"), "ai": check_run("expired", required=False)}
    expect("expired, no vote yet: still a review", pr.waiting_for(seen(expired)), "a review, then CI queued again")
    expect("expired and approved: queue it again", pr.waiting_for(seen(expired, approved)), "CI to be queued again")
    expect("expired and rejected: changes from us", pr.waiting_for(seen(expired, {"Ada": "rejected"})), "changes from us")
    expect("an optional expired one changes nothing",
           pr.waiting_for(seen({"gate": check_run("passed"), "ai": check_run("expired", required=False)})), "a review")
    expect("a required failure, even with another expired",
           pr.waiting_for(seen({**expired, "lint": check_run("failed")})), "a CI fix")
    expect("a conflict first", pr.waiting_for(seen(expired, approved, conflicts=True)), "a conflict fix")
    expect("green, no vote", pr.waiting_for(seen({"gate": check_run("passed")})), "a review")
    expect("green and approved", pr.waiting_for(seen({"gate": check_run("passed")}, approved)), "the merge")
    expect("running", pr.waiting_for(seen({"gate": check_run("running")})), "CI")
    expect("stacked with no CI", pr.waiting_for(seen({}, target="feat/base")), "the PR into feat/base to merge first")

    print(f"\n{len(failures)} failure(s)" if failures else "\nall passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
