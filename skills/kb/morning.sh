#!/bin/bash
# Run by the daily-sync skill after the morning sync: curates every day not yet curated,
# up to a week back, then hands the new notes to the sync.
set -u
if [ -f "$HOME/.claude/kb/kb.env" ]; then
  set -a
  . "$HOME/.claude/kb/kb.env"
  set +a
fi
[ "${KB_CURATE:-on}" = off ] && exit 0
kb_bin() {
  local candidate
  for candidate in "${KB_BIN:-}" "$HOME/.claude/kb/venv/bin/kb" "$HOME/.claude/kb/venv/Scripts/kb.exe"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] && { printf '%s' "$candidate"; return; }
  done
  command -v kb 2>/dev/null
}
KB=$(kb_bin)
[ -n "$KB" ] || exit 0
STATE="$HOME/.claude/kb"
LOG="$STATE/curate.log"
mkdir -p "$STATE"

yesterday() {
  date -d "yesterday" +%F 2>/dev/null || date -v-1d +%F
}
day_before() {
  date -d "$1 -1 day" +%F 2>/dev/null || date -j -v-1d -f %F "$1" +%F
}

last=$(cat "$STATE/curated-until" 2>/dev/null)
end=$(yesterday)
days=()
day=$end
for _ in 1 2 3 4 5 6 7; do
  [ -n "$last" ] && [ ! "$day" \> "$last" ] && break
  days=("$day" "${days[@]}")
  day=$(day_before "$day")
done
[ ${#days[@]} -gt 0 ] || exit 0

for day in "${days[@]}"; do
  printf '%s curate %s\n' "$(date '+%F %T')" "$day" >>"$LOG"
  if "$KB" curate --day "$day" >>"$LOG" 2>&1; then
    printf '%s\n' "$day" >"$STATE/curated-until"
  else
    printf '%s curate %s failed\n' "$(date '+%F %T')" "$day" >>"$LOG"
    break
  fi
done
"$KB" index >>"$LOG" 2>&1
[ -f "$HOME/.claude-sync/sync.sh" ] && bash "$HOME/.claude-sync/sync.sh" bg >/dev/null 2>&1
exit 0
