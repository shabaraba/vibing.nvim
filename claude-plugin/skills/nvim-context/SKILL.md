---
name: nvim-context
description: Use when working on a project that has a running Neovim instance via vibing.nvim (the vibing-nvim MCP server is connected). Reads live buffer, window, cursor, and selection state through vibing-nvim MCP tools before editing or answering, instead of relying on stale file reads or guesses about what the user currently has open or selected.
user-invocable: false
---

# Neovim Live Context

When the `vibing-nvim` MCP server is available, a real Neovim instance is running and its
in-memory state (open buffers, splits, cursor position, unsaved edits) is the ground truth —
it can differ from what's on disk. Prefer live state over assumptions whenever the user
references "this file", "current buffer", "my selection", "what I have open", etc.

## Workflow

1. **Ground yourself first.** Call `mcp__vibing-nvim__nvim_get_info` for the active file and
   `mcp__vibing-nvim__nvim_list_windows` / `mcp__vibing-nvim__nvim_list_buffers` to see everything
   open across splits/tabs before deciding which file the user means.
2. **Use the real selection.** If the user mentions a visual selection, call
   `mcp__vibing-nvim__nvim_get_visual_selection` instead of asking them to paste code.
3. **Respect unsaved state.** `mcp__vibing-nvim__nvim_get_buffer` returns the buffer's current
   content, which may include unsaved edits that differ from the file on disk — read the buffer,
   not the file, when a buffer for that path is already loaded.
4. **Cursor-relative requests.** For "here", "at my cursor", "this function" type requests, use
   `mcp__vibing-nvim__nvim_get_cursor` to resolve the exact line/column before acting.
5. **Actual edits still go through your normal file tools** (Read/Edit/Write). The vibing-nvim
   MCP tools are for observing and controlling the live editor (buffers, windows, commands), not
   a substitute for making code changes.

## Graceful degradation

If `vibing-nvim` MCP calls fail or time out (no running Neovim instance, RPC not connected),
don't retry repeatedly — but don't fail silently either:

1. **Say so.** Note briefly that live Neovim state isn't available, so you're working from
   on-disk file content, which may not match what the user actually has open (unsaved edits, a
   different selection, etc.).
2. **Fall back to normal file-based tools** (Read/Edit/Write) for the rest of the task.
3. **Don't mix stale and live state.** If `vibing-nvim` calls start succeeding again later in the
   same task (Neovim was started or reconnected), re-read the buffer via
   `mcp__vibing-nvim__nvim_get_buffer` before making further edits — don't keep acting on the
   on-disk snapshot from the degraded period.
