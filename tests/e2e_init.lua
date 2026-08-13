-- init.lua for the *child* Neovim an E2E spec drives over RPC.
--
-- tests/minimal_init.lua is the parent's init: it wires up plenary so the specs can run. The
-- child needs something different — vibing.nvim actually set up, so `:Vibing*` commands exist at
-- all. Pointing the child at minimal_init left it with no commands, which is why every spec's
-- first `:VibingChat` did nothing.

vim.opt.runtimepath:append(vim.fn.getcwd())

vim.opt.swapfile = false
vim.opt.backup = false

-- Chats go to a per-child temp directory. The default ("project") writes into the repository's
-- own .vibing/chat/, so running the suite used to leave real chat files behind — in CI, in a
-- checkout, every time.
local chat_dir = vim.fn.tempname() .. "/chat"
vim.fn.mkdir(chat_dir, "p")

require("vibing").setup({
  chat = {
    save_location_type = "custom",
    save_dir = chat_dir,
  },
  -- MCP stays on: nvim_ask_user_question_spec exists to drive that tool, so a child without the
  -- RPC server could never pass it. Concurrent children do not collide — the server walks to the
  -- next free port when 9876 is taken.
  mcp = { enabled = true },
  -- The child is a throwaway editor in a temp directory, and these specs are about UI plumbing,
  -- not about permissions. It also has to be bypassPermissions to work at all: under acceptEdits
  -- the CLI refuses the vibing-nvim MCP tool ("Claude requested permissions to use ..."), and
  -- listing it in --allowedTools does not change that — verified with the exact tool name, the
  -- `mcp__<server>__*` form and the bare `mcp__<server>` form. vibing's own PreToolUse hook
  -- allows it; the CLI's gate is what refuses, and this is the only lever that clears it.
  permissions = { mode = "bypassPermissions" },
})

-- Read back by cleanup_instance so the parent can delete what this child wrote.
vim.g.vibing_e2e_chat_dir = chat_dir
