# Sourced from ~/.zshrc. In a WebStorm or Ghostty terminal tab, offer to resume
# the Claude Code session that was left open in this directory (recorded by the
# SessionStart hook and never cleanly ended). Runs once, at the first prompt.

[[ ( "$TERMINAL_EMULATOR" == "JetBrains-JediTerm" || "$TERM_PROGRAM" == "ghostty" ) && -o interactive && -z "$CLAUDECODE" ]] || return 0

_claude_resume_here() {
  add-zsh-hook -d precmd _claude_resume_here
  local reg="$HOME/.claude/session-registry" rec id cwd name transcript reply
  for rec in "$reg"/*.json(N); do
    cwd=$(jq -r '.cwd // empty' "$rec" 2>/dev/null) || continue
    [[ "$cwd" == "$PWD" ]] || continue
    id=$(jq -r '.session_id' "$rec")
    _claude_session_live "$id" && continue

    mkdir -p "$reg/claimed" "$reg/skipped"
    mv "$rec" "$reg/claimed/" 2>/dev/null || continue

    transcript=$(jq -r '.transcript_path // empty' "$reg/claimed/${rec:t}")
    name=""
    [[ -f "$transcript" ]] && name=$(grep -a '"type":"custom-title"' "$transcript" | tail -n 1 | jq -r '.customTitle // empty')
    [[ -z "$name" ]] && name=$(jq -r '.session_name // empty' "$reg/claimed/${rec:t}")

    print -P "🌊 Claude session %B${name:-$id}%b was open here."
    reply=""
    read -t 10 -k 1 "reply?Resume it in this tab? [Y/n] " 2>/dev/null
    print
    if [[ "$reply" == [nN] ]]; then
      mv "$reg/claimed/${rec:t}" "$reg/skipped/"
      continue
    fi
    rm -f "$reg/claimed/${rec:t}"
    if [[ -n "$CLAUDE_RESUME_DRY" ]]; then
      print "dry-run: claude --resume $id"
    else
      command claude --resume "$id"
    fi
    return
  done
}

_claude_session_live() {
  local f pid
  for f in "$HOME/.claude/sessions"/*.json(N); do
    [[ "$(jq -r '.sessionId // empty' "$f" 2>/dev/null)" == "$1" ]] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

autoload -U add-zsh-hook
add-zsh-hook precmd _claude_resume_here
