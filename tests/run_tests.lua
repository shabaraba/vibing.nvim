-- Test runner script that exits after tests complete
-- This ensures Neovim doesn't hang after tests finish

vim.cmd("PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }")

-- Schedule quit after a short delay to allow test output to flush
vim.defer_fn(function()
  vim.cmd("qa!")
end, 100)
