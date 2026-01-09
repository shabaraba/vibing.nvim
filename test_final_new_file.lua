-- Final test for new file diff functionality
-- This file should display diff with all lines as additions

local FinalTest = {}

function FinalTest.initialize()
  print("Initializing final test")
  return {
    name = "FinalTest",
    version = "1.0.0",
    initialized = true,
  }
end

function FinalTest.execute(params)
  if not params then
    error("Parameters required")
  end

  local result = {}
  for key, value in pairs(params) do
    result[key] = value * 100
  end

  return result
end

function FinalTest.cleanup()
  print("Cleanup completed")
end

return FinalTest
