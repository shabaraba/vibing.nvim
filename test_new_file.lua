-- This is a completely new file created for testing
-- Testing if gd works on newly created files

local NewModule = {}

function NewModule.test()
  print("This is a new file")
  return true
end

function NewModule.another_function()
  local x = 42
  return x * 2
end

return NewModule
