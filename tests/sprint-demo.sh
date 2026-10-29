#!/bin/bash
# sprint-demo's editing script: clips with a banner and captions, cards, the joined video's chapters and
# captions, and the Jira sprint request. The video checks are skipped without ffmpeg (with drawtext).
set -u
KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
bash "$KIT/skills/sprint-demo/scripts/selftest.sh"
