-- Minimal init.lua for running tests
-- Sets up plenary and vibing.nvim for testing

-- Add vibing.nvim to runtimepath
vim.opt.runtimepath:append(".")

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

-- Set shorter timeout for test runner
vim.g.plenary_timeout = 5000

print("Test environment initialized")
