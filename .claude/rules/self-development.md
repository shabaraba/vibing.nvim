# Developing vibing.nvim with vibing.nvim

Three mistakes this project makes over and over, each of which succeeds quietly.

**A worktree outside `.vibing/worktrees/`.** Use
`git worktree add -b <branch> .vibing/worktrees/<branch>` (what the `vibing-worktree-create` skill
does) and update the chat's `working_dir` frontmatter to match. `.vibing/worktrees/` is the
convention every chat is told about in its system prompt, and `.vibing/` is git-ignored so the
per-request diff snapshot skips it. A worktree anywhere else has its whole checkout reported in the
parent's `### Modified Files`.

**Serena (or any generic LSP tool) instead of the vibing-nvim MCP LSP tools.**
`mcp__vibing-nvim__nvim_lsp_references`, not `mcp__serena__lsp_references`. The vibing-nvim tools
query the **running** Neovim with its live LSP servers; generic tools analyze separate file copies
and miss runtime state. Same for buffer and window operations (`nvim_get_buffer`,
`nvim_set_buffer`, `nvim_list_windows`, `nvim_load_buffer`).

**Omitting `rpc_port`.** Pass the value from your system prompt on every MCP call. Worktrees and
concurrent chats make several live Neovim instances the normal case, and omitting it falls back to
the instance registry, which only answers when exactly one is live. `process.env.VIBING_NVIM_RPC_PORT`
is **not** a substitute: MCP clients forward only a fixed whitelist of variables plus the server
registration's static `env` block, so it never reaches the MCP server process.

Context is managed with `:VibingContext <file>` / `:VibingClearContext`. Inside a vibing.nvim
session `VIBING_NVIM_CONTEXT=true` and `VIBING_NVIM_RPC_PORT=<port>` are set.
