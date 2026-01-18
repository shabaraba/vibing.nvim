# Developing vibing.nvim with vibing.nvim

When you (Claude Agent SDK) are working on vibing.nvim itself, follow these guidelines to leverage vibing.nvim's built-in workflows.

## Preferred Workflows

**For Feature Development:**

1. Use `:VibingChatWorktree <branch-name>` instead of manual `git worktree` commands
   - Automatically creates isolated development environment
   - Copies essential configs (`.gitignore`, `package.json`, `tsconfig.json`)
   - Symlinks `node_modules` to avoid duplicate installations
   - Saves chat files in main repo at `.vibing/worktrees/<branch>/`

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

## Example Development Workflow

```typescript
// ✅ CORRECT - vibing.nvim-aware workflow
// 1. Create worktree for new feature
await use_mcp_tool('vibing-nvim', 'nvim_execute', {
  command: 'VibingChatWorktree right feature-new-ui',
});

// 2. Load file in background for LSP analysis
const { bufnr } = await use_mcp_tool('vibing-nvim', 'nvim_load_buffer', {
  filepath: 'lua/vibing/ui/chat_buffer.lua',
  rpc_port: process.env.VIBING_NVIM_RPC_PORT,
});

// 3. Use LSP to find references
const refs = await use_mcp_tool('vibing-nvim', 'nvim_lsp_references', {
  bufnr: bufnr,
  line: 100,
  col: 5,
  rpc_port: process.env.VIBING_NVIM_RPC_PORT,
});

// 4. Make changes via Edit tool
// ... (Agent SDK's Edit tool)

// 5. Build and test
await use_mcp_tool('vibing-nvim', 'nvim_execute', {
  command: '!npm run build && npm test',
});
```

```typescript
// ❌ WRONG - Generic workflow
// 1. Manual git worktree (misses vibing.nvim setup)
await bash("git worktree add .worktrees/feature-new-ui");

// 2. Use Serena LSP tools (analyzes stale file copies)
const refs = await use_mcp_tool("serena", "lsp_references", { ... });

// 3. Edit files without Neovim awareness
// (may conflict with open buffers)
```

## Common Mistakes and How to Fix Them

**Mistake 1: Using `git worktree` instead of `:VibingChatWorktree`**

- ❌ Wrong: `git worktree add .worktrees/feature-branch`
- ✅ Correct: `:VibingChatWorktree feature-branch`
- Why: Manual git worktree doesn't copy configs or symlink node_modules

**Mistake 2: Using Serena LSP tools instead of vibing-nvim MCP tools**

- ❌ Wrong: `mcp__serena__lsp_references`
- ✅ Correct: `mcp__vibing-nvim__nvim_lsp_references` with `rpc_port`
- Why: Serena analyzes stale file copies, vibing-nvim connects to running instance

**Mistake 3: Forgetting to pass `rpc_port` to MCP tools**

- ❌ Wrong: `mcp__vibing-nvim__nvim_list_windows({})`
- ✅ Correct: `mcp__vibing-nvim__nvim_list_windows({ rpc_port: process.env.VIBING_NVIM_RPC_PORT })`
- Why: Multiple Neovim instances may be running, need to target the correct one

## Environment Variables

When vibing.nvim is running, these environment variables are set:

- `VIBING_NVIM_CONTEXT=true` - Indicates you're running inside vibing.nvim
- `VIBING_NVIM_RPC_PORT=<port>` - RPC port for this Neovim instance (always pass to MCP tools)

Always check and use these variables in your workflows.
