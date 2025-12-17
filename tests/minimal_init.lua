-- Minimal init.lua for running tests
-- Sets up plenary and vibing.nvim for testing

-- Add vibing.nvim to runtimepath
vim.opt.runtimepath:append(".")

-- Add plenary to runtimepath (assumes it's installed via package manager)
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
