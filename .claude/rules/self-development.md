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

**Naming an `rpc_port` on an MCP call.** Omit it. The MCP server process is bound to the Neovim
that launched the chat through `VIBING_NVIM_RPC_PORT`, and a subagent shares that already-bound
connection. The argument survives only as a compatibility override for a server started manually
outside vibing.nvim. Putting the numeric port back into a prompt, a task brief or a tool call is
what #730 removed: it changes on every Neovim restart, so it breaks the cached prompt prefix.

Context is managed with `:VibingContext <file>` / `:VibingClearContext`. Inside a vibing.nvim
session `VIBING_NVIM_CONTEXT=true` and `VIBING_NVIM_RPC_PORT=<port>` are set.
