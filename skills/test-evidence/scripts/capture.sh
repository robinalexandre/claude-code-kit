#!/bin/bash
# Captures one window or one screen region (never the whole screen unless asked) and converts videos.
#   capture.sh doctor                          what this machine can do
#   capture.sh windows                         lists visible window titles, to pick a --window
#   capture.sh shot <out.png> TARGET           screenshot of TARGET
#   capture.sh record <out.mp4> TARGET [--max <seconds>]   records TARGET until `stop` or --max (default 120)
#   capture.sh stop                            stops the running `record`
#   capture.sh mp4 <in> <out.mp4> [from_s] [to_s]   re-encodes (and trims) a video to an H.264 mp4 that Jira, Azure DevOps and GitHub play
#   capture.sh gif <in> <out.gif> [width] [fps]   turns a short video into a GIF that renders inline (default 960 px, 8 fps)
# TARGET: --window "<part of the title>" (brought to the front first), --region <x,y,w,h> or --full.
set -eu

PIDFILE="${TMPDIR:-/tmp}/test-evidence-record.pid"

die() {
  echo "$*" >&2
  exit 1
}

os() {
  case "$(uname -s)" in
    Darwin) echo mac ;;
    MINGW* | MSYS* | CYGWIN*) echo windows ;;
    *) if [ -n "${WAYLAND_DISPLAY:-}" ]; then echo wayland; else echo x11; fi ;;
  esac
}

native() { if command -v cygpath > /dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi; }

need() { command -v "$1" > /dev/null || die "$1 is missing. $2"; }
need_ffmpeg() { need ffmpeg "Install it (brew install ffmpeg, scoop install ffmpeg, winget install Gyan.FFmpeg, apt install ffmpeg)."; }

# Windows: PowerShell gets the script as -EncodedCommand, so quotes survive and the execution policy doesn't apply.
ps() {
  local enc
  enc=$(printf '%s\n%s' "\$ProgressPreference = 'SilentlyContinue'; \$ErrorActionPreference = 'Stop'" "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  powershell.exe -NoProfile -NonInteractive -EncodedCommand "$enc" | tr -d '\r'
}

PS_WIN='Add-Type @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public static class W {
  public delegate bool P(IntPtr h, IntPtr l);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Rt, B; }
  [DllImport("user32.dll")] static extern bool EnumWindows(P f, IntPtr l);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out R r, int s);
  public static List<KeyValuePair<IntPtr, string>> All() {
    var l = new List<KeyValuePair<IntPtr, string>>();
    EnumWindows((h, x) => { if (IsWindowVisible(h)) { var s = new StringBuilder(512); GetWindowText(h, s, 512); if (s.Length > 0) l.Add(new KeyValuePair<IntPtr, string>(h, s.ToString())); } return true; }, IntPtr.Zero);
    return l;
  }
}
"@
[void][W]::SetProcessDPIAware()'

list_windows() {
  case "$(os)" in
    windows) ps "$PS_WIN"'
[W]::All() | ForEach-Object { $_.Value }' ;;
    mac) osascript -e 'set out to ""
tell application "System Events" to repeat with p in (processes whose visible is true)
  repeat with w in windows of p
    set out to out & (name of p) & ": " & (name of w) & linefeed
  end repeat
end repeat
return out' ;;
    x11)
      if command -v wmctrl > /dev/null; then wmctrl -l | cut -d' ' -f5-
      else
        need xdotool "Install xdotool or wmctrl."
        xdotool search --onlyvisible --name . getwindowname %@
      fi
      ;;
    wayland) die "Wayland doesn't let tools list windows: use --region (slurp prints one) or the browser tools." ;;
  esac
}

# Prints "x y w h" of the first visible window whose title contains $1, after bringing it to the front.
window_rect() {
  local r
  case "$(os)" in
    windows)
      r=$(TITLE="$1" ps "$PS_WIN"'
$m = [W]::All() | Where-Object { $_.Value -like "*$env:TITLE*" } | Select-Object -First 1
if (-not $m) { exit 3 }
if ([W]::IsIconic($m.Key)) { [void][W]::ShowWindow($m.Key, 9) }
[void][W]::SetForegroundWindow($m.Key)
Start-Sleep -Milliseconds 400
$r = New-Object W+R
[void][W]::DwmGetWindowAttribute($m.Key, 9, [ref]$r, 16)
"$($r.L) $($r.T) $($r.Rt - $r.L) $($r.B - $r.T)"') || true
      ;;
    mac)
      r=$(TITLE="$1" osascript -e 'set t to system attribute "TITLE"
tell application "System Events" to repeat with p in (processes whose visible is true)
  repeat with w in windows of p
    if (name of w as text) contains t or (name of p as text) contains t then
      set frontmost of p to true
      perform action "AXRaise" of w
      delay 0.4
      set {x, y} to position of w
      set {ww, hh} to size of w
      return (x as text) & " " & (y as text) & " " & (ww as text) & " " & (hh as text)
    end if
  end repeat
end repeat
return ""' 2> /dev/null) || die "macOS refused: allow your terminal in System Settings > Privacy & Security > Accessibility."
      ;;
    x11)
      need xdotool "Install xdotool to capture a window."
      local id
      id=$(xdotool search --onlyvisible --name "$1" 2> /dev/null | head -n 1)
      if [ -n "$id" ]; then
        xdotool windowactivate --sync "$id" > /dev/null 2>&1 || true
        sleep 0.4
        eval "$(xdotool getwindowgeometry --shell "$id")"
        r="$X $Y $WIDTH $HEIGHT"
      fi
      ;;
    wayland) die "Wayland doesn't let tools find windows: use --region (slurp prints one) or the browser tools." ;;
  esac
  [ -n "${r:-}" ] || die "No visible window matches \"$1\". See: capture.sh windows"
  echo "$r"
}

full_rect() {
  case "$(os)" in
    windows) ps "$PS_WIN"'
Add-Type -AssemblyName System.Windows.Forms
$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
"$($b.Left) $($b.Top) $($b.Width) $($b.Height)"' ;;
    x11)
      need xdpyinfo "Install xdpyinfo (x11-utils), or use --region."
      xdpyinfo | awk '/dimensions:/ { split($2, d, "x"); print 0, 0, d[1], d[2]; exit }'
      ;;
    *) echo full ;;
  esac
}

# Parses TARGET into RECT ("x y w h", or "full" where the tool captures the whole screen itself).
target() {
  RECT=""
  MAX=120
  while [ $# -gt 0 ]; do
    case "$1" in
      --window) RECT=$(window_rect "${2:?--window needs a title}") || exit 1; shift ;;
      --region) RECT=$(printf '%s' "${2:?--region needs x,y,w,h}" | tr ',' ' '); shift ;;
      --full) RECT=$(full_rect) ;;
      --max) MAX=${2:?--max needs seconds}; shift ;;
      *) die "Unknown option: $1" ;;
    esac
    shift
  done
  [ -n "$RECT" ] || die "Say what to capture: --window \"<title>\", --region x,y,w,h, or --full (shows everything on screen)."
  if [ "$RECT" != full ]; then
    set -- $RECT
    [ $# -eq 4 ] || die "A region is x,y,w,h."
    # H.264 needs even sizes.
    RECT="$1 $2 $(($3 / 2 * 2)) $(($4 / 2 * 2))"
  fi
}

shot() {
  local out=${1:?shot needs an output file}
  shift
  target "$@"
  mkdir -p "$(dirname "$out")"
  set -- $RECT
  case "$(os)" in
    mac) if [ "$RECT" = full ]; then screencapture -x "$out"; else screencapture -x -R "$1,$2,$3,$4" "$out"; fi ;;
    windows)
      OUT=$(native "$out") X=$1 Y=$2 WW=$3 HH=$4 ps "$PS_WIN"'
Add-Type -AssemblyName System.Drawing
$bmp = New-Object System.Drawing.Bitmap ([int]$env:WW), ([int]$env:HH)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen([int]$env:X, [int]$env:Y, 0, 0, $bmp.Size)
$bmp.Save($env:OUT, [System.Drawing.Imaging.ImageFormat]::Png)' > /dev/null
      ;;
    x11)
      if command -v ffmpeg > /dev/null; then
        ffmpeg -loglevel error -y -f x11grab -video_size "${3}x${4}" -i "${DISPLAY:-:0}+$1,$2" -frames:v 1 "$out"
      else
        need import "Install ffmpeg or ImageMagick."
        import -window root -crop "${3}x${4}+$1+$2" "$out"
      fi
      ;;
    wayland)
      need grim "Install grim."
      if [ "$RECT" = full ]; then grim "$out"; else grim -g "$1,$2 ${3}x$4" "$out"; fi
      ;;
  esac
  [ -s "$out" ] || die "Nothing captured."
  echo "$out"
}

record() {
  local out=${1:?record needs an output file} raw ctl pid
  shift
  target "$@"
  [ ! -f "$PIDFILE" ] || die "A recording is already running: capture.sh stop"
  mkdir -p "$(dirname "$out")"
  raw="${out%.*}.rec.mkv"
  # The recorder reads its stdin from this file: `stop` writes "q" to it, which ends ffmpeg and
  # screencapture cleanly everywhere (Git Bash can't send a native Windows process a Ctrl-C).
  ctl="${out%.*}.rec.ctl"
  : > "$ctl"
  set -- $RECT
  case "$(os)" in
    mac)
      raw="${out%.*}.rec.mov"
      if [ "$RECT" = full ]; then tail -f "$ctl" | screencapture -x -v -V "$MAX" "$raw" &
      else tail -f "$ctl" | screencapture -x -v -V "$MAX" -R "$1,$2,$3,$4" "$raw" & fi
      ;;
    windows)
      need_ffmpeg
      tail -f "$ctl" | ffmpeg -loglevel error -y -f gdigrab -framerate 15 -draw_mouse 1 -offset_x "$1" -offset_y "$2" -video_size "${3}x${4}" -i desktop \
        -t "$MAX" -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p "$(native "$raw")" &
      ;;
    x11)
      need_ffmpeg
      tail -f "$ctl" | ffmpeg -loglevel error -y -f x11grab -framerate 15 -video_size "${3}x${4}" -i "${DISPLAY:-:0}+$1,$2" \
        -t "$MAX" -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p "$raw" &
      ;;
    wayland)
      need wf-recorder "Install wf-recorder, or record the browser page with screencast_start."
      if [ "$RECT" = full ]; then tail -f "$ctl" | wf-recorder -f "$raw" > /dev/null 2>&1 &
      else tail -f "$ctl" | wf-recorder -g "$1,$2 ${3}x$4" -f "$raw" > /dev/null 2>&1 & fi
      ;;
  esac
  pid=$!
  printf '%s\n%s\n' "$pid" "$ctl" > "$PIDFILE"
  echo "Recording (max ${MAX}s). Stop with: capture.sh stop"
  if [ "$(os)" = wayland ]; then
    (sleep "$MAX" && kill -INT "$pid" 2> /dev/null) &
  fi
  # Not `wait`: it waits for the whole pipeline, and tail -f only exits once it writes to the closed pipe.
  while kill -0 "$pid" 2> /dev/null; do sleep 0.5; done
  printf 'q' >> "$ctl"
  wait || true
  rm -f "$PIDFILE" "$ctl"
  [ -s "$raw" ] || die "The recorder wrote nothing (on macOS, allow your terminal in Privacy & Security > Screen Recording)."
  if command -v ffmpeg > /dev/null; then
    mp4 "$raw" "$out" && rm -f "$raw"
  else
    echo "ffmpeg is missing, so the take stays as $raw." >&2
  fi
}

stop() {
  [ -f "$PIDFILE" ] || die "No recording running."
  local pid ctl
  { read -r pid; read -r ctl; } < "$PIDFILE"
  [ -n "$ctl" ] && [ -f "$ctl" ] && printf 'q' >> "$ctl"
  # wf-recorder ignores stdin and stops on SIGINT; sending it to the others is harmless.
  [ "$(os)" = wayland ] && kill -INT "$pid" 2> /dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -f "$PIDFILE" ] || break
    sleep 0.5
  done
  if [ -f "$PIDFILE" ] && kill -0 "$pid" 2> /dev/null; then
    kill -INT "$pid" 2> /dev/null || true
    sleep 2
    kill "$pid" 2> /dev/null || true
    # Git Bash can't always signal a native process: fall back to its Windows PID.
    [ -f "/proc/$pid/winpid" ] && taskkill //F //PID "$(cat "/proc/$pid/winpid")" > /dev/null 2>&1 || true
  fi
  echo "Stopped. The record command finishes the mp4 in a few seconds."
}

mp4() {
  local cut=()
  need_ffmpeg
  [ -z "${3:-}" ] || cut+=(-ss "$3")
  [ -z "${4:-}" ] || cut+=(-to "$4")
  ffmpeg -loglevel error -y -i "$(native "$1")" ${cut[@]+"${cut[@]}"} -an -c:v libx264 -preset veryfast -crf 26 -pix_fmt yuv420p \
    -vf "scale=trunc(iw/2)*2:trunc(ih/2)*2" -movflags +faststart "$(native "$2")"
  echo "$2"
}

gif() {
  need_ffmpeg
  ffmpeg -loglevel error -y -i "$(native "$1")" \
    -vf "fps=${4:-8},scale=${3:-960}:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer" \
    "$(native "$2")"
  echo "$2"
}

doctor() {
  local t
  echo "platform: $(os)"
  if command -v ffmpeg > /dev/null; then echo "ffmpeg: $(ffmpeg -version | head -n 1)"; else echo "ffmpeg: missing (video on Windows and Linux, mp4 and GIF everywhere)"; fi
  case "$(os)" in
    x11) for t in xdotool wmctrl xdpyinfo import; do command -v $t > /dev/null && echo "$t: ok" || echo "$t: missing"; done ;;
    wayland) for t in grim slurp wf-recorder; do command -v $t > /dev/null && echo "$t: ok" || echo "$t: missing"; done ;;
  esac
  command -v perl > /dev/null && echo "perl: ok (redact.sh)" || echo "perl: missing (needed by redact.sh)"
  command -v jq > /dev/null && echo "jq: ok (attach.sh)" || echo "jq: missing (needed by attach.sh)"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  doctor) doctor ;;
  windows) list_windows ;;
  shot) shot "$@" ;;
  record) record "$@" ;;
  stop) stop ;;
  mp4) mp4 "$@" ;;
  gif) gif "$@" ;;
  *)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
    exit 1
    ;;
esac
