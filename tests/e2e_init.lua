-- init.lua for the *child* Neovim an E2E spec drives over RPC.
--
-- tests/minimal_init.lua is the parent's init: it wires up plenary so the specs can run. The
-- child needs something different — vibing.nvim actually set up, so `:Vibing*` commands exist at
-- all. Pointing the child at minimal_init left it with no commands, which is why every spec's
-- first `:VibingChat` did nothing.

-- Derived from this file's own location rather than from the child's cwd, because a spec may
-- start the child in a throwaway project directory (plugin_dir_spec does, to get a
-- `.vibing/plugins/` that is not the developer's real one). `getcwd()` would then add the wrong
-- directory and no `:Vibing*` command would exist.
local repo_root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json") or vim.fn.getcwd()
vim.opt.runtimepath:append(repo_root)

vim.opt.swapfile = false
vim.opt.backup = false

-- Chats go to a per-child temp directory. The default ("project") writes into the repository's
-- own .vibing/chat/, so running the suite used to leave real chat files behind — in CI, in a
-- checkout, every time.
--
-- The path comes from the parent (spawn_nvim_instance sets $VIBING_E2E_CHAT_DIR) so that cleanup
-- never has to ask this process where it wrote; rpcrequest has no timeout, and a wedged child
-- would otherwise hang the suite. The fallback keeps this init usable when run by hand.
local chat_dir = vim.env.VIBING_E2E_CHAT_DIR
if not chat_dir or chat_dir == "" then
  chat_dir = vim.fn.tempname() .. "/chat"
end
vim.fn.mkdir(chat_dir, "p")

require("vibing").setup({
  chat = {
    save_location_type = "custom",
    save_dir = chat_dir,
  },
  -- Already the default; stated because nvim_ask_user_question_spec exists to drive that tool and
  -- a child without the RPC server could never pass it, so this is not safe to "tidy away".
  -- Concurrent children do not collide — the server walks to the next free port when 9876 is taken.
  mcp = { enabled = true },
  -- The child is a throwaway editor in a temp directory, and these specs are about UI plumbing,
  -- not about permissions. It also has to be bypassPermissions to work at all: under acceptEdits
  -- the CLI refuses the vibing-nvim MCP tool ("Claude requested permissions to use ..."), and
  -- listing it in --allowedTools does not change that — verified with the exact tool name, the
  -- `mcp__<server>__*` form and the bare `mcp__<server>` form. vibing's own PreToolUse hook
  -- allows it; the CLI's gate is what refuses, and this is the only lever that clears it.
  permissions = { mode = "bypassPermissions" },
})
