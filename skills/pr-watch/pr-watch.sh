#!/bin/bash
# Runs pr_watch.py with whichever Python 3.9+ this computer has (python3 on macOS/Linux, python on Windows).
# A version-manager shim (pyenv, mise, asdf) can take seconds to start, on every click of the pr-pane:
# the interpreter it resolves to is remembered on this computer and run directly.
SK=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/pr-watch/python"
if [ -f "$CACHE" ]; then
  py=$(cat "$CACHE")
  [ -x "$py" ] && exec "$py" -I "$SK/pr_watch.py" "$@"
fi
for py in python3 python; do
  command -v "$py" > /dev/null 2>&1 || continue
  real=$("$py" -c 'import sys; print(sys.executable if sys.version_info >= (3, 9) else "")' 2> /dev/null | tr -d '\r')
  [ -n "$real" ] || continue
  command -v cygpath > /dev/null 2>&1 && real=$(cygpath -u "$real")
  mkdir -p "$(dirname "$CACHE")" && printf '%s\n' "$real" > "$CACHE"
  exec "$real" -I "$SK/pr_watch.py" "$@"
done
echo "pr-watch: Python 3.9+ not found" >&2
exit 1
