-- Test file for issue #207 diff verification
-- This file will be modified by Claude to test the gd keymap

local M = {}

function M.hello()
  print("Hello, World!")
  print("This is a test modification for issue #207")
end

function M.greet(name)
  print("Hello, " .. name)
  return "Greeting sent to " .. name
end

function M.farewell(name)
  print("Goodbye, " .. name)
end

return M
