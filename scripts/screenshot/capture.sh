#!/usr/bin/env bash
#
# Screenshot a real, running Neovim from a container that has no X server.
#
#   capture.sh start [--cols N] [--rows N] [--session NAME] [--] [nvim args...]
#   capture.sh keys  [--session NAME] <tmux send-keys arguments...>
#   capture.sh shoot [--session NAME] [--scale N] <out.png>
#   capture.sh stop  [--session NAME]
#
# tmux holds the pty, `capture-pane -e` returns the visible screen with its truecolor SGR
# sequences, ansi2html.py lays that grid out as positioned cells, and headless Chromium paints
# it. Nothing is intercepted or reconstructed: what is on the screen is what lands in the PNG.
#
# THIS IS FOR THE CLAUDE CODE ON THE WEB CONTAINER ONLY. It refuses to run anywhere else, on
# purpose — see the guard below.
set -euo pipefail

# A developer on their own machine is looking at Neovim already, and this would start a second
# hidden one, install nothing it needs, and leave a tmux session behind. There is no case where
# it is the right tool locally, so it does not run there.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  cat >&2 <<'MSG'
capture.sh: refusing to run outside Claude Code on the web.

This script screenshots a headless Neovim because the remote container has no display. On a
local machine, look at your editor — or drive it directly if you want an image.

Set CLAUDE_CODE_REMOTE=true only if you genuinely have this container's tmux, DejaVu Sans Mono
and Playwright Chromium at the paths below.
MSG
  exit 2
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
WORK="${VIBING_SHOT_DIR:-${TMPDIR:-/tmp}/vibing-screenshot}"

# `chrome --headless`, NOT headless_shell, is the trap here: the full browser subtracts its
# (nonexistent) window UI from --window-size, so the page is silently clipped from the bottom.
# The Neovim statusline disappears while every row above it still looks correct, which reads as
# a CSS bug rather than a viewport one. headless_shell honours the size exactly.
BROWSER="${VIBING_SHOT_BROWSER:-}"
if [ -z "$BROWSER" ]; then
  BROWSER="$(find /opt/pw-browsers -maxdepth 3 -type f -name headless_shell -print -quit 2>/dev/null || true)"
fi

SESSION="vibing-shot"
COLS=150
ROWS=40
SCALE="${SCALE:-2}"
FONT_PX=15
LINE_PX=21
PAD_PX=14

die() { printf 'capture.sh: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is not installed"; }

geometry_path() { printf '%s/%s.geometry' "$WORK" "$SESSION"; }

cmd_start() {
  need tmux
  need nvim
  mkdir -p "$WORK"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  # A dedicated init so the screenshot shows vibing.nvim actually set up (`:Vibing*` commands
  # present), rather than the plugin merely on runtimepath.
  tmux new-session -d -s "$SESSION" -x "$COLS" -y "$ROWS" -c "$REPO_ROOT" \
    "TERM=xterm-256color nvim -u '$HERE/nvim_init.lua' $*"
  printf '%s %s\n' "$COLS" "$ROWS" > "$(geometry_path)"
  # Neovim needs to finish drawing before the first capture; a capture taken too early shows a
  # blank pane, which looks exactly like a broken renderer.
  sleep 3
  printf 'started tmux session %s (%sx%s)\n' "$SESSION" "$COLS" "$ROWS" >&2
}

cmd_keys() {
  need tmux
  tmux send-keys -t "$SESSION" "$@"
  sleep 1
}

cmd_shoot() {
  local out="${1:?usage: capture.sh shoot <out.png>}"
  need tmux
  [ -n "$BROWSER" ] || die "no headless_shell found under /opt/pw-browsers (set VIBING_SHOT_BROWSER)"
  [ -x "$BROWSER" ] || die "$BROWSER is not executable"
  mkdir -p "$WORK"

  if [ -r "$(geometry_path)" ]; then
    read -r COLS ROWS < "$(geometry_path)"
  fi

  local width height
  width=$(python3 -c "print(round($COLS * $FONT_PX * 0.6023) + 2*$PAD_PX)")
  height=$(python3 -c "print($ROWS * $LINE_PX + 2*$PAD_PX)")

  tmux capture-pane -e -p -t "$SESSION" > "$WORK/pane.ansi"
  python3 "$HERE/ansi2html.py" --cols "$COLS" --font-px "$FONT_PX" \
    --line-px "$LINE_PX" --pad-px "$PAD_PX" < "$WORK/pane.ansi" > "$WORK/pane.html"
  "$BROWSER" --headless --no-sandbox --disable-gpu --hide-scrollbars \
    --force-device-scale-factor="$SCALE" --window-size="$width,$height" \
    --screenshot="$out" "file://$WORK/pane.html" 2>/dev/null

  [ -s "$out" ] || die "the browser wrote no image"
  printf '%s  (%sx%s grid, %sx%s css, %sx scale)\n' "$out" "$COLS" "$ROWS" \
    "$width" "$height" "$SCALE" >&2
  printf 'verify with: python3 %s/pxbox.py %s --expect-height %s\n' \
    "$HERE" "$out" "$(( (ROWS - 2) * LINE_PX ))" >&2
}

cmd_stop() {
  tmux kill-session -t "$SESSION" 2>/dev/null || true
  printf 'stopped %s\n' "$SESSION" >&2
}

[ $# -gt 0 ] || die "usage: capture.sh {start|keys|shoot|stop} ..."
action="$1"; shift

# Options common to every subcommand are consumed first so `keys` and `start` can still take
# arbitrary trailing arguments.
while [ $# -gt 0 ]; do
  case "$1" in
    --session) SESSION="$2"; shift 2 ;;
    --cols) COLS="$2"; shift 2 ;;
    --rows) ROWS="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

case "$action" in
  start) cmd_start "$@" ;;
  keys) cmd_keys "$@" ;;
  shoot) cmd_shoot "$@" ;;
  stop) cmd_stop ;;
  *) die "unknown subcommand: $action" ;;
esac
