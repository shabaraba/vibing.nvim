-- init.lua for the Neovim a screenshot is taken of.
--
-- Not tests/minimal_init.lua (that one wires up plenary for the parent test process and never
-- calls setup(), so no `:Vibing*` command would exist) and not tests/e2e_init.lua (that one
-- redirects chats to a throwaway temp directory, which then shows up in the statusline as a
-- path no reader can make sense of).
--
-- Chats land in the project's real .vibing/chat/, which is already git-ignored.

local repo_root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json")
  or vim.fn.getcwd()
vim.opt.runtimepath:append(repo_root)

vim.opt.swapfile = false
vim.opt.backup = false
-- Every capture starts a fresh Neovim in the same container; sharing one ShaDa file across them
-- risks the same "read a half-written file" failure the test suite disables it for.
vim.opt.shadafile = "NONE"

vim.opt.termguicolors = true
vim.opt.number = true
-- One statusline for the whole editor rather than one per split: at these widths a per-window
-- statusline spends most of its room on a truncated path.
vim.opt.laststatus = 3

require("vibing").setup({
  mcp = { enabled = true },
  permissions = { mode = "acceptEdits" },
})
