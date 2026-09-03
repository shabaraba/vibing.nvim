---
name: remote-screenshot
description:
  Take a real screenshot of a running Neovim from inside the Claude Code on the web container,
  which has no X server. Use when asked to show what a UI change looks like, or to attach an
  image of the chat buffer, a split layout, an approval prompt or a picker. Requires
  CLAUDE_CODE_REMOTE=true — on a local machine there is nothing to do here, since the developer
  is already looking at their editor.
---

# Screenshotting Neovim in the web container

**Applies only to Claude Code on the web.** `CLAUDE_CODE_REMOTE` must be `true`; the script
refuses to run otherwise and that refusal is correct, not an obstacle to work around. If you are
on a local machine, stop and say so — the user can see their own editor, and starting a hidden
second Neovim to photograph it helps nobody.

## The sequence

```bash
S=scripts/screenshot
$S/capture.sh start --cols 150 --rows 40 lua/vibing/core/utils/git_snapshot.lua
$S/capture.sh keys ':VibingChat right' Enter
$S/capture.sh shoot /tmp/shot.png
python3 $S/pxbox.py /tmp/shot.png --expect-height 798   # (rows - 2) * 21
$S/capture.sh stop
```

Then hand the PNG to the user with `SendUserFile`.

`capture.sh shoot` prints the exact `pxbox.py` command to run. **Run it.** A capture whose
bottom rows were clipped is a plausible-looking screenshot of a slightly different screen, and
the difference between 21px and 1px of painted height does not survive downscaling — you will
not catch it by looking, and you will describe a statusline that is not in the image. `pxbox.py`
exits non-zero when the painted region is short.

`scripts/screenshot/README.md` has the mechanism, the `headless_shell` trap, and why each
terminal cell is its own element. Read it if something renders wrong.

## Do not fabricate the contents

`capture-pane` returns the actual screen buffer, which is the whole point: the frontmatter,
statusline path and highlighting in the image are Neovim's own output. Two ways to throw that
away, both of which produce an image that lies:

- **Writing a transcript into the chat buffer to make it look busy.** Text you typed is not the
  renderer's output. If a screenshot needs a real assistant turn — tool headers,
  `### Modified Files`, streaming — that costs real tokens, so ask first and say that is what
  the image shows.
- **Describing what the screenshot shows without reading it back.** Open the PNG and look
  before you narrate it.

Typing an **unsent** `## User` message is fine and authentic — that is a real editor state a
user reaches by typing.

## Housekeeping

`start` writes a chat into the project's real `.vibing/chat/`, which is git-ignored, so nothing
lands in a commit. Still run `git status` before committing, and `capture.sh stop` when done —
a forgotten session keeps a Neovim alive for the rest of the container's life.
