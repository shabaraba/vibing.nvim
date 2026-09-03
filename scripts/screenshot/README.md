# Screenshotting Neovim from a headless container

Takes a real screenshot of a real, running Neovim in an environment with no X server — the
Claude Code on the web container. Used to show what a change looks like, rather than describing
it.

**This is for that container only.** `capture.sh` refuses to run unless
`CLAUDE_CODE_REMOTE=true`; on a local machine you are already looking at your editor, and the
script would start a second hidden one and leave a tmux session behind. Nothing here is loaded
into a session's context automatically — the instructions live in
`.claude/skills/remote-screenshot/SKILL.md`, which is read only when invoked.

## How it works

```text
tmux (pty)          holds nvim at a fixed COLS x ROWS
  |  capture-pane -e     the visible screen, with its truecolor SGR sequences
ansi2html.py        one absolutely positioned element per terminal cell
  |
headless_shell      --screenshot at 2x
```

Nothing is intercepted or reconstructed. `capture-pane` returns the screen buffer, so whatever
Neovim actually drew is what lands in the PNG — real syntax highlighting, real statusline, real
cursor position.

## Usage

```bash
S=scripts/screenshot
$S/capture.sh start --cols 150 --rows 40 lua/vibing/core/utils/git_snapshot.lua
$S/capture.sh keys ':VibingChat right' Enter
$S/capture.sh keys 'G' 'o' 'なぜこの順序なのか？' Escape
$S/capture.sh shoot /tmp/nvim.png
$S/capture.sh stop
```

`shoot` prints the `pxbox.py` command to verify the result with. Run it — see below.

## Two things that cost an hour each

**Use `headless_shell`, never `chrome --headless`.** The full browser subtracts its
(nonexistent) window UI from `--window-size`, so the page is silently clipped from the bottom.
The symptom is that Neovim's statusline is absent while every row above it looks perfect — which
reads as a CSS bug, not a viewport one. `getComputedStyle` and `getBoundingClientRect` both
reported the cells at their correct `9x21`; the layout was right the whole time.

**Verify by measuring, not by looking.** A clipped capture is a plausible-looking screenshot of
a slightly different screen, and 21px versus 1px of painted height is not something the eye
catches in a downscaled image. `pxbox.py` decodes the PNG with `zlib` alone and reports the
bounding box of everything that is not page background:

```bash
python3 scripts/screenshot/pxbox.py /tmp/nvim.png --expect-height 798
```

It exits non-zero when the painted region is shorter than expected. `--expect-height` should be
about `(rows - 2) * 21`: the bottom row is usually the message line, which is blank.

## Why one element per cell

This repository's source is Japanese-heavy, and no font in the container renders DejaVu Sans
Mono's Latin advance and a CJK glyph at exactly a 1:2 ratio. A flowed `<pre>` therefore drifts a
little further out of alignment on every wide character, until the two window splits no longer
line up and the screenshot misrepresents the layout. Positioning each cell at a multiple of the
Latin advance, with `unicodedata.east_asian_width` deciding whether it occupies one column or
two, makes the grid exact by construction.

## Requirements in the container

`tmux`, `nvim` (installed by `.claude/hooks/session-start.sh`), `python3`, DejaVu Sans Mono plus
a CJK monospace fallback, and Playwright's Chromium under `/opt/pw-browsers`. Override the
browser with `VIBING_SHOT_BROWSER` and the scratch directory with `VIBING_SHOT_DIR`.

## What is tested, and what is not

No repository gate reads `.py` or `.sh`: `check` compiles `lua/` only, eslint matches
`js`/`mjs`/`ts`, and prettier matches `js`/`ts`/`json`/`md`/`yml`. So the two Python tools carry
their own regression tests in `tests/screenshot-tools.test.mjs`, which `npm run test:node` picks
up — the SGR parser, the wide-character grid, the explicit cell height, and pxbox's five PNG row
filters and clipping verdict. They shell out to `python3`, which is therefore a requirement of
`test:node` as well.

`capture.sh` itself is not covered: driving it means starting tmux and a browser, which is the
whole environment it exists for. Verify a change to it by taking a screenshot and running
`pxbox.py` on the result.
