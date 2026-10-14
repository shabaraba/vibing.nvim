-- Isolate one assertion's scenario while retaining PlenaryBustedDirectory's explicit deadline.
dofile("tests/minimal_init.lua")
require("plenary.busted")
local selected = vim.env.VIBING_HOOK_TEST_CASE
local original_it = it
it = function(name, callback)
  if not selected or name == selected then
    original_it(name, callback)
  end
end
