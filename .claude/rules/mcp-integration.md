# MCP Integration

An async RPC server (`infrastructure/rpc/server.lua`) is queried by the Node MCP server
(`claude-plugin/mcp-server/`) acting as a TCP client. Nothing is installed: `build.sh` builds the
server and `--plugin-dir` hands it to the CLI per session.

The tool catalogue, the orchestration tools, annotations and background LSP analysis are in
`handbook/mcp-tools.md`; the shipped tool descriptions are the authority for arguments. Setup is
`claude-plugin/mcp-server/README.md` and `handbook/lazy-setup-example.lua`.

## Invariants

- **The prefix depends on how the server was registered**: `mcp__vibing-nvim__<tool>` for a plain
  user-level entry, `mcp__plugin_vibing-nvim_vibing-nvim__<tool>` when it arrives inside the
  plugin — which is the normal case on claude. That second form is built from the **plugin** name
  and the MCP server name, both from `claude-plugin/.claude-plugin/plugin.json`. The marketplace
  name never appears in it, and `tests/lua/core/constants/tools_spec.lua` reads `plugin.json` for
  exactly that reason. On codex the server is registered per run with
  `-c mcp_servers.vibing-nvim.*` instead, so the plain form is what that backend sees.
- **`VIBING_NVIM_MCP_TOOL_PATTERNS` (`core/constants/tools.lua`) is hand-maintained**, because
  `--allowedTools` accepts nothing but literals. A stale entry does not break chats — the hook's
  suffix match is what decides — which is why a dead one went unnoticed for so long.
- **`rpc_port` has to be named explicitly on every call, and a subagent does not inherit it.** The
  system prompt tells the model to pass its own and to forward it in any task prompt it hands a
  subagent. The one home for both this and the prefix rule is
  `claude-plugin/skills/nvim-context/SKILL.md` → "Calling the tools"; other skills state it in a
  line and point there, because a skill is loaded on its own.
- **Never assume `winnr: 0`.** `nvim_get_window_info({ winnr: 0 })` returns the _active_ window,
  which is often not the one the user is looking at. Call `nvim_list_windows()` first, match on
  `buffer_name`/`is_current`, and carry that `winnr` through `nvim_win_open_file` →
  `nvim_set_cursor` → `nvim_highlight_range`. None of them errors when pointed at the wrong
  window, so the failure is silent.
- **A chat is addressed by `file_path` or `bufnr`, and the path is the primary form.** Passing
  both is refused rather than resolved in favour of one.
- **`queue_if_busy` returning "queued" means no request has started yet.** An orchestrator that
  reads it as "sent" polls a transcript that has not moved.

vibing.nvim invokes the CLI with `--setting-sources user,project,local`
(`config.agent.setting_sources`), so the user's own MCP servers, `.claude/commands/`,
`.claude/skills/` and subagents are all available inside vibing.nvim sessions with no extra
configuration.
