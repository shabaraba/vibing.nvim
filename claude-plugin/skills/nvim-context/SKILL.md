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

## Calling the tools

Two things decide whether a `vibing-nvim` tool call reaches the editor the user is looking at.
Both apply to every skill and subagent in this plugin, so they are stated once here.

**Which name.** Tools are written below as `mcp__vibing-nvim__<tool>`, which is the plain
user-level MCP server registration. Loaded as a Claude Code plugin — which is how vibing.nvim
itself provides them, handing the CLI this directory with `--plugin-dir` — they appear as
`mcp__plugin_vibing-nvim_vibing-nvim__<tool>` instead. If the plain prefix is not available, look
for a tool whose name **ends** in the one you need rather than assuming it is missing.

**Which instance.** Every tool takes an `rpc_port` naming the target Neovim.

- Inside a vibing.nvim chat, the port is in your system prompt for the turn — pass that exact
  value on every call.
- A subagent does **not** inherit it. Take it from your task prompt, and if it isn't there, call
  `nvim_list_instances` and use the port it reports.
- Anywhere else (an ordinary Claude Code session that loaded this plugin some other way — a
  `--plugin-dir` of your own, or a leftover install), `nvim_list_instances` is the only way to
  know. If it lists more than one, say which you found and ask rather than guessing.

Omitting `rpc_port` works only while exactly one Neovim is live: reads fall back to the instance
registry, and writes refuse outright. Worktrees and concurrent chats make more than one the normal
case, so treat the fallback as a diagnostic, not a default.

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
