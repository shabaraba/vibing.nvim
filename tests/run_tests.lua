-- Test runner script that exits after tests complete
-- This ensures Neovim doesn't hang after tests finish

-- Override Plenary's on_exit callback to force quit
local busted = require("plenary.busted")
local original_run = busted.run

busted.run = function(...)
  local result = original_run(...)

  -- Force quit after a short delay
  vim.defer_fn(function()
    os.exit(0)
  end, 500)

  return result
end

vim.cmd("PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }")
