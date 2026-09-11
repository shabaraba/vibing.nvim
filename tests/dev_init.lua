-- init.lua for manually exercising *this* checkout in a throwaway Neovim.
--
-- `tests/minimal_init.lua` wires up plenary for the spec runner and `tests/e2e_init.lua` is the
-- child an E2E spec drives over RPC. This one is for a human: it starts a real editor with this
-- copy of vibing.nvim loaded, so a git worktree can be tried out without repointing the `dev =
-- true` entry in the developer's own lazy.nvim config (and without restarting the editor the
-- chat driving the work is running in).
--
--     nvim -u tests/dev_init.lua
--     nvim --listen /tmp/vibing-dev.sock -u tests/dev_init.lua   -- to drive it over RPC
--
-- The root is derived from this file's own location, not from `getcwd()`, for the same reason
-- `e2e_init.lua` does it: the editor may be started from anywhere, and resolving to the wrong
-- checkout is exactly the failure this file exists to avoid.
local repo_root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json") or vim.fn.getcwd()
vim.opt.runtimepath:append(repo_root)

vim.opt.swapfile = false
vim.opt.backup = false

-- The "number" view style of mini.diff colors line numbers, which needs them shown at all.
vim.opt.number = true

-- mini.diff is an optional dependency of the diff viewer. lazy.nvim does not run here, so take
-- it from where lazy installed it. Absence is not an error: the viewer is supposed to fall back
-- to the built-in patch viewer in exactly that case, and this init is also how that fallback
-- gets tested (move the directory aside, or just do not install it).
local mini_diff_path = vim.fn.expand("~/.local/share/nvim/lazy/mini.diff")
if vim.fn.isdirectory(mini_diff_path) == 1 then
  vim.opt.runtimepath:append(mini_diff_path)
  local mini_diff = require("mini.diff")
  mini_diff.setup({
    -- Same configuration the plugin documents for this integration: no source of its own, so
    -- nothing is shown until vibing.nvim sets reference text on a buffer.
    source = mini_diff.gen_source.none(),
    view = { style = "number" },
  })
end

require("vibing").setup({
  -- The MCP server is a separate build artifact (`./build.sh`) that a fresh worktree does not
  -- have, and enabling it here would also fight the developer's real Neovim for the RPC port.
  -- Nothing in the diff viewer path needs it.
  mcp = { enabled = false },
  permissions = { mode = "acceptEdits" },
})
