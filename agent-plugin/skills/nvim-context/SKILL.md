---
name: nvim-context
description: Use only when the user's request depends on live Neovim state, such as the current buffer, cursor, visual selection, unsaved edits, windows, tabs, or an explicit request to use nvim tools. Do not use for ordinary questions or tasks that do not reference the active editor.
user-invocable: false
---

# Neovim Live Context

## Activation gate

Run this gate before calling any vibing-nvim MCP tool. The presence of a running Neovim
instance or an available MCP server is not, by itself, a reason to activate this skill.

Activate this skill only when the user's request depends on live editor state, including:

- the current or open file, buffer, window, tab, or split
- the cursor position, a visual selection, or code "here"
- unsaved edits in Neovim
- opening, focusing, jumping to, highlighting, or resizing editor windows
- executing a Neovim command or querying the live Neovim instance
- an explicit request to use nvim, vibing-nvim, or Neovim tools

Do not activate this skill for:

- ordinary questions, explanations, or meta questions about this skill or plugin
- general programming questions that do not depend on the active editor
- repository tasks that can be handled from on-disk files without live editor state
- requests that merely happen inside a vibing.nvim chat

If the request does not clearly match an activation case, do not call an nvim tool, do not
perform a live-state preflight, and do not announce one.

## Active workflow

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

**Which instance.** Inside a vibing.nvim chat, omit `rpc_port`: the MCP server process is already
bound to the Neovim that launched the chat, and subagents share that connection. The optional
argument exists only for a server started manually outside vibing.nvim. In that standalone case,
call `nvim_list_instances` first; use the sole result, or match an explicit cwd/project clue you
already know. If several remain plausible, say which you found and ask rather than guessing. An
unbound server answers reads against a single live instance but refuses anything that changes
state until you name the port, so pass the one `nvim_list_instances` reported.

## Workflow after activation

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
