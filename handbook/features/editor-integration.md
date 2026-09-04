# Editor Integration: Code Tour and Debugger Analysis

Moved out of `.claude/rules/features.md`.

## Code Tour

`claude-plugin/skills/vibing-code-tour/SKILL.md` turns "explain how X works" into a walkthrough
the editor performs: each stop is a real file opened at a real line (`nvim_win_open_file` +
`nvim_set_cursor`), and the whole route is left in the quickfix list so the user can replay it
with `:cnext`/`:cprev` afterwards.

Both calls take the target window explicitly, and the skill insists on it: `nvim_win_open_file`
restores focus before returning, so the window showing the file is never the current one. A
`nvim_set_cursor` without `winnr` moves the chat's cursor instead — and succeeds, so the tour
looks like it is working while the code window never moves.

The quickfix half is the MCP tool `nvim_set_qflist`
(`claude-plugin/mcp-server/src/tools/qflist.ts` → `infrastructure/rpc/handlers/qflist.lua`). It
always pushes a **new** list
(`vim.fn.setqflist({}, " ", ...)`), so whatever the user had in quickfix stays reachable under
`:colder` — which is also why the skill must call it exactly once per tour, or `:cnext` walks a
different list than the one being narrated. `open: true` opens the quickfix window but restores
focus, matching `win_open_file`. `col` is 1-based here (native quickfix), unlike the 0-based `col`
everywhere else in this tool surface.

A stop naming a file that does not exist rejects the whole call: the tool result does reach the
model, so a hard error is actionable, while a silently shortened tour is not. That existence check
is Lua-side, not in the MCP server, because relative paths resolve against the target instance's
cwd — often a worktree the server process knows nothing about.

The pacing question in the skill inherits AskUserQuestion's turn-killing behavior
(`handbook/features/chat-ui.md`), so the skill is instructed to write the tour's position and
remaining stops into its chat message before every ask — the transcript is the only place that
state survives.

## Debugger Analysis (nvim-dap)

When the debugger is stopped, the agent can look at the actual runtime state instead of reasoning
about the source: `nvim_dap_get_state`, `nvim_dap_get_stack_trace`, `nvim_dap_get_variables`,
`nvim_dap_set_breakpoint`, `nvim_dap_evaluate` (`infrastructure/rpc/handlers/dap.lua`).

nvim-dap is an **optional** dependency. Every entry point reports "nvim-dap is not installed" or
"no debug session is running" rather than erroring, so the agent gets an explanation it can act on
— which is also why `nvim_dap_get_state` exists and its description tells the model to call it
first.

DAP requests are callback-based while RPC handlers return a value, so each request is awaited with
`vim.wait`. That is only safe because the RPC server already dispatches handlers inside
`vim.schedule`: we are on the main loop, and `vim.wait` keeps processing events, which is what lets
the adapter's reply arrive at all.

`vim.wait` does still block the editor, though, so a handler that issues several requests spends
**one shared budget** across them (`deadline()` in `dap.lua`). `dap_get_variables` asks for scopes
and then for the variables of each scope; with a per-request timeout a slow adapter and a frame
with four scopes would freeze Neovim for 25 seconds on a single tool call.

`dap_get_variables` expands only the top level of each scope. A deep object graph would flood the
chat, and the agent can follow up with `dap_evaluate` on whatever it actually wants. Note that
`dap_evaluate` runs **in the debuggee** — an expression with side effects will have them, and the
tool description says so.

`:VibingDebugAnalyze` and `:VibingDebugHelp` send a request to the chat. They send only the
request, never a state dump: the agent fetches whatever depth it needs through the tools above.
`config.dap.enabled` additionally subscribes to nvim-dap's stopped event; `auto_analyze_on_error`
(default `true`) fires on exceptions, `auto_analyze_on_breakpoint` (default `false`) on ordinary
breakpoints — a breakpoint is something the user placed on purpose, and spending tokens unattended
every time one is hit gets in the way. The whole feature is off until `dap.enabled` is set.

**Implementation:** `application/debug/analyze.lua` (commands + stopped-event listener),
`infrastructure/rpc/handlers/dap.lua`, `claude-plugin/mcp-server/src/{tools,handlers}/dap.ts`.
