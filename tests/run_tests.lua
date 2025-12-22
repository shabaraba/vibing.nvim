-- Test runner script that exits after tests complete
-- This ensures Neovim doesn't hang after tests finish

-- Set autocmd to exit after tests complete
vim.api.nvim_create_autocmd("User", {
  pattern = "PlenaryTestFinished",
  callback = function()
    -- Exit immediately after tests finish
    vim.defer_fn(function()
      os.exit(vim.v.shell_error)
    end, 100)
  end,
})

-- Fallback: Force exit after reasonable time if event doesn't fire
vim.defer_fn(function()
  -- This should not normally execute if tests complete properly
  vim.cmd("cquit")
end, 300000) -- 5 minutes max

vim.cmd("PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }")
