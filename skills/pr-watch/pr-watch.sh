#!/bin/bash
# Runs pr_watch.py with whichever Python 3 this computer has (python3 on macOS/Linux, python on Windows).
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for py in python3 python; do
  if command -v "$py" > /dev/null 2>&1 && "$py" -c 'import sys; sys.exit(sys.version_info < (3, 9))' 2> /dev/null; then
    exec "$py" -I "$SK/pr_watch.py" "$@"
  fi
done
echo "pr-watch: Python 3.9+ not found" >&2
exit 1
