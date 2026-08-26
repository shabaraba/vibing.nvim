# MCP Integration (Model Context Protocol)

vibing.nvim provides MCP server integration so Claude Code can interact with a running Neovim
instance without deadlocks: an async RPC server (`lua/vibing/infrastructure/rpc/server.lua`,
`vim.loop` TCP,
`vim.schedule()` for safe API calls) is queried by the Node MCP server
(`claude-plugin/mcp-server/`) acting as a TCP client, so both buffer reads and writes are possible.
Nothing is installed: `build.sh` builds the server, and the plugin that carries it is handed to
the CLI per session with `--plugin-dir` (`architecture.md` → "Self-Hosted Claude Code Plugin").
See
`claude-plugin/mcp-server/README.md` and `handbook/lazy-setup-example.lua` for setup details;
don't duplicate them here.

## User MCP Servers, Slash Commands, Skills, and Subagents

vibing.nvim invokes the `claude` CLI with `--setting-sources user,project,local` (configurable via
`config.agent.setting_sources`), so your existing `~/.claude.json` MCP servers,
`.claude/commands/` project slash commands, `.claude/skills/`, and global settings/subagents are
all available inside vibing.nvim sessions automatically — no extra configuration needed.

## Naming the Tool and the Instance

Two facts decide whether a call reaches the editor the user is looking at, and both have one home
in the distributed plugin: `claude-plugin/skills/nvim-context/SKILL.md` → "Calling the tools". The
other skills and the `nvim-navigator` agent state the rule in a line each and point there, rather
than restating the reasoning — a skill is loaded on its own, so a bare cross-reference would leave
the rule unstated.

**The prefix depends on how the server was registered.** `mcp__vibing-nvim__<tool>` for a plain
user-level entry, `mcp__plugin_vibing-nvim_vibing-nvim__<tool>` when it arrives inside the plugin
— which is the normal case, since vibing.nvim self-hosts that plugin with `--plugin-dir`.

Note what builds that second form: the **plugin** name and the MCP server name, both from
`claude-plugin/.claude-plugin/plugin.json`. The marketplace name never appears in it. This rule
used to be written down as `mcp__plugin_<marketplace>_…`, and
`tests/lua/core/constants/tools_spec.lua` read `marketplace.json` to enforce it — so after the
marketplace was renamed to `vibing`, the list carried an `mcp__plugin_vibing_vibing-nvim__*` entry
the CLI has never once emitted, and a test defended it. Both are gone; the spec reads `plugin.json`
now.

`VIBING_NVIM_MCP_TOOL_PATTERNS` (`core/constants/tools.lua`) still has to be maintained by hand,
because `--allowedTools` accepts nothing but literals. A stale entry there does not break chats:
the hook's suffix match is what actually decides, which is exactly why nothing noticed the dead
one for so long.

**The port has to be named explicitly**, and a subagent does not inherit the chat's. The system
prompt therefore tells the model both to pass its own `rpc_port` and to forward it in any task
prompt it hands a subagent.

## Available MCP Tools

Prefix with `mcp__vibing-nvim__`:

- **Buffer**: `nvim_get_buffer`, `nvim_set_buffer`, `nvim_list_buffers`, `nvim_get_info`,
  `nvim_load_buffer`
- **Cursor/Selection**: `nvim_get_cursor`, `nvim_set_cursor`, `nvim_get_visual_selection`
- **Window/Pane**: `nvim_list_windows`, `nvim_get_window_info`, `nvim_get_window_view`,
  `nvim_list_tabpages`, `nvim_set_window_size`, `nvim_focus_window`, `nvim_win_set_buf`,
  `nvim_win_open_file`
- **Commands**: `nvim_execute`
- **Highlighting**: `nvim_highlight_range`, `nvim_clear_highlight` (see "Showing Code" below)
- **Annotations**: `nvim_annotate`, `nvim_clear_annotations` (see "Inline Review Notes" below)
- **Chat**: `nvim_ask_user_question` (renders a choice list in the chat buffer — see
  `features.md`), `nvim_chat_send_message`, `nvim_chat_create` (see "Orchestration" below)
- **Instances**: `nvim_list_instances`
- **Quickfix**: `nvim_set_qflist` (pushes a new list; the previous one survives under `:colder`)
- **Debugger**: `nvim_dap_get_state`, `nvim_dap_get_stack_trace`, `nvim_dap_get_variables`,
  `nvim_dap_set_breakpoint`, `nvim_dap_evaluate` (nvim-dap is optional — every one of these
  reports it as missing rather than failing)
- **LSP**: `nvim_lsp_definition`, `nvim_lsp_references`, `nvim_lsp_hover`, `nvim_diagnostics`,
  `nvim_lsp_document_symbols`, `nvim_lsp_type_definition`, `nvim_lsp_call_hierarchy_incoming`,
  `nvim_lsp_call_hierarchy_outgoing`

**Window identification (important):** `nvim_get_window_info({ winnr: 0 })` returns the
**currently active** window, not necessarily the one the user is visually looking at (e.g. the
chat window may not be active when a request is sent). Always call `nvim_list_windows()` first,
match the target by `buffer_name`/`is_current`, and use the returned `winnr` — don't assume
`winnr: 0` is the right window.

## Showing Code

When the user asks to see code, open it rather than describing where it is: `nvim_list_windows` →
pick a window that isn't the chat → `nvim_win_open_file` → `nvim_set_cursor` → `nvim_highlight_range`.
The CLI's system prompt tells the model to do this, so the tools exist to make that instruction
actionable.

**Carry the `winnr` through the whole sequence.** `nvim_win_open_file` restores focus before it
returns, so the window it opened is not the current one. `nvim_set_cursor` without a `winnr` moves
whatever window is active — the chat — and `nvim_highlight_range` wants the `bufnr` the open
returned, not `0`. Both take the target explicitly for this reason; neither errors when pointed at
the wrong one, so the failure is silent.

`nvim_highlight_range` puts an extmark range in the `vibing_highlight` namespace using the
`VibingHighlight` group, which is `default link`ed to `Visual` so `hi VibingHighlight ...` in a
user's config overrides it. It clears itself after `duration_ms` (default 3000; `0` keeps it), and
a second call to the same buffer replaces the first rather than stacking. Out-of-range lines are
clamped to the buffer rather than rejected — search results go stale by a line or two, and pointing
at roughly the right place beats refusing to point.

## Orchestration

`nvim_chat_create({ rpc_port, position?, working_dir? })` creates a chat buffer and returns
`{ bufnr, file_path, working_dir, position, saved }` as JSON, so one chat can spawn worker chats,
brief each with `nvim_chat_send_message`, and poll them with `nvim_get_buffer` — which reports a
chat buffer's `responding` / `idle` status as a second content block.

The workflow is the bundled `vibing-orchestrate` skill. Why `position` defaults to `back`, why the
chat file is written at creation, why the status is a field rather than a text heuristic, and what
is deliberately out of scope: `architecture.md` → "Multi-Agent Orchestration".

## Inline Review Notes

`nvim_annotate` puts a review point under the line it is about, as extmark `virt_lines` in the
`vibing_annotations` namespace. The file is never written and `modified` never gets set. Severity
picks between `VibingAnnotationInfo` / `Warn` / `Error`, each `default link`ed to the matching
`DiagnosticVirtualText*` group so a user's own `hi` command overrides it. Every annotation line is
prefixed with `┃ ` so a note can't be misread as code.

Annotations are **not persisted** — unloading the buffer takes them with it. That is the intended
lifetime: a review is read once and dismissed. Editing near an annotation moves it the way
extmarks normally move; no attempt is made to re-anchor it.

`nvim_clear_annotations` clears one buffer, or every buffer when `bufnr` is omitted.
`:VibingClearAnnotations` is the same thing from the user's side.

## Background LSP Analysis

All LSP tools work on any loaded buffer, not just the active one. Load a file in the background
with `nvim_load_buffer` (returns `bufnr`), then pass that `bufnr` to LSP tools — this analyzes
code (e.g. call hierarchy) without leaving the current window or switching buffers; the LSP server
keeps analyzing every loaded buffer regardless of display state.
