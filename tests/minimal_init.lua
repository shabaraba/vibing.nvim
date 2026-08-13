-- Minimal init.lua for running tests
-- Sets up plenary and vibing.nvim for testing

-- Add vibing.nvim to runtimepath.
-- Resolved from this script's own path (always absolute when invoked via `-u <abs path>`),
-- not from the process cwd: E2E specs may spawn the child Neovim with cwd set to a throwaway
-- test repo, in which case "." would not point at the plugin root at all.
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":p:h:h")
vim.opt.runtimepath:append(plugin_root)

-- Add plenary to runtimepath
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
  vim.opt.runtimepath:append(plenary_path)
end

-- Check plenary is available
local ok, plenary = pcall(require, "plenary")
if not ok then
  print("plenary.nvim is required for testing")
  print("Install it with your package manager")
  os.exit(1)
end

-- Basic vim setup for tests
vim.opt.swapfile = false
vim.opt.backup = false

print("Test environment initialized")
