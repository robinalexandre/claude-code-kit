"""pr-watch's push after a change of the user's: an ack, an unack or a park starts the config sync
(`sync.sh bg`) right away, a `status` does not, and a watch folder with no sync.sh beside it starts
nothing.

    python tests/pr-watch-push.py [skills/pr-watch]
"""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import time

from pathlib import Path


def main() -> int:
    skill = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent / "skills" / "pr-watch")
    root = Path(tempfile.mkdtemp())
    sync = root / "sync"
    marker = root / "pushed"
    os.environ.update({"PR_WATCH_DIR": str(sync / "pr-watch"), "PR_WATCH_SHARED": "off",
                       "XDG_CACHE_HOME": str(root / "cache"), "CLAUDE_CONFIG_DIR": str(root / "claude")})
    spec = importlib.util.spec_from_file_location("pr_watch", skill / "pr_watch.py")
    pr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(pr)
    failures: list[str] = []

    def expect(what: str, got: object, wanted: object) -> None:
        print(f"{'ok  ' if got == wanted else 'FAIL'} {what}: {got}")
        if got != wanted:
            failures.append(what)

    def pushes(argv: list[str]) -> list[str]:
        marker.unlink(missing_ok=True)
        pr.main(argv)
        for _ in range(50):
            if marker.exists():
                break
            time.sleep(0.1)
        return marker.read_text(encoding="utf-8").split() if marker.exists() else []

    run = "https://github.com/acme/shop/actions/runs/7"
    pr.save(pr.BUILDS, {"checked": pr._now(), "builds": [
        {"url": run, "repo": "shop", "pipeline": "tests", "number": "7", "status": "failed",
         "queued": pr._now(), "ended": pr._now()}]})

    expect("no sync.sh beside the watch folder: nothing started", pushes(["ack", run]), [])
    expect("the ack is saved all the same", run in json.loads(pr.ACKS.read_text(encoding="utf-8")), True)

    (sync / "sync.sh").write_text(f'#!/bin/bash\nprintf "%s\\n" "$@" > "{marker.as_posix()}"\n', encoding="utf-8", newline="\n")
    expect("ack starts sync.sh bg", pushes(["ack", run]), ["bg"])
    expect("unack starts it too", pushes(["unack", run]), ["bg"])
    expect("a failed unack still starts it (harmless)", pushes(["unack", run]), ["bg"])
    expect("status does not", pushes(["status"]), [])
    expect("list does not", pushes(["list"]), [])

    if failures:
        print(f"{len(failures)} failed: {', '.join(failures)}")
        return 1
    print("all passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
