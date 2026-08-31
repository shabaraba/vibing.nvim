# Developing vibing.nvim with vibing.nvim

When you are working on vibing.nvim itself, follow these guidelines to leverage vibing.nvim's
built-in workflows.

## Preferred Workflows

**For Feature Development:**

1. Use the `vibing-worktree-{list,create,attach,run,finish}` skills for isolated development
   environments — ask in natural language ("split this off into its own worktree", "what
   worktrees exist", "attach to the auth-fix worktree", "clean up this worktree"). They run plain
   `git worktree` commands under `.vibing/worktrees/<branch>/` and update the current chat's
   `working_dir` frontmatter; there is no separate metadata file or lifecycle state to manage.

**For Buffer/Window Operations:**

1. Use vibing.nvim MCP tools (`mcp__vibing-nvim__*`) instead of generic file operations
   - `mcp__vibing-nvim__nvim_get_buffer` - Read buffer content
   - `mcp__vibing-nvim__nvim_set_buffer` - Write buffer content
   - `mcp__vibing-nvim__nvim_list_windows` - List all windows
   - `mcp__vibing-nvim__nvim_load_buffer` - Load file in background (no window switching)
   - See "MCP Integration" section for full list

**For LSP Operations:**

1. ALWAYS use vibing-nvim LSP tools, NOT Serena or other generic LSP tools
   - vibing-nvim tools connect to the RUNNING Neovim instance with active LSP servers
   - Other tools analyze separate file copies and miss runtime state

**For Context Management:**

1. Use `:VibingContext <file>` to add files to context
2. Use `:VibingClearContext` to clear context

## Common Mistakes and How to Fix Them

**Mistake 1: Placing a worktree outside `.vibing/worktrees/`**

- ❌ Wrong: `git worktree add ../feature-branch` or `git worktree add .worktrees/feature-branch`
- ✅ Correct: `git worktree add -b feature-branch .vibing/worktrees/feature-branch` (what the
  `vibing-worktree-create` skill does), then update the chat's `working_dir` frontmatter to match
- Why: `.vibing/worktrees/` is the convention every vibing.nvim chat is told about via its system
  prompt, and `.vibing/` is already git-ignored so the per-request diff snapshot skips it; a
  worktree placed elsewhere won't be picked up by that convention, and its whole checkout would
  show up in the parent worktree's `### Modified Files`

**Mistake 2: Using Serena LSP tools instead of vibing-nvim MCP tools**

- ❌ Wrong: `mcp__serena__lsp_references`
- ✅ Correct: `mcp__vibing-nvim__nvim_lsp_references` with `rpc_port`
- Why: Serena analyzes stale file copies, vibing-nvim connects to running instance

**Mistake 3: Forgetting to pass `rpc_port` to MCP tools**

- ❌ Wrong: `mcp__vibing-nvim__nvim_list_windows({})`
- ✅ Correct: `mcp__vibing-nvim__nvim_list_windows({ rpc_port: <the value in your system prompt> })`
- Why: Multiple Neovim instances may be running, need to target the correct one. Worktrees and
  concurrent chats make this the normal case, not the exception
- Note: `process.env.VIBING_NVIM_RPC_PORT` does **not** work as a substitute. MCP clients forward
  only a fixed whitelist of variables (`HOME`, `PATH`, `SHELL`, ...) plus the static `env` block in
  the server's registration, so that variable never reaches the MCP server process. Omitting
  `rpc_port` falls back to the instance registry, which only answers when exactly one Neovim is
  live — otherwise it errors and tells you to pick one with `nvim_list_instances`

## Environment Variables

When vibing.nvim is running, these environment variables are set:

- `VIBING_NVIM_CONTEXT=true` - Indicates you're running inside vibing.nvim
- `VIBING_NVIM_RPC_PORT=<port>` - RPC port for this Neovim instance (always pass to MCP tools)

Always check and use these variables in your workflows.
