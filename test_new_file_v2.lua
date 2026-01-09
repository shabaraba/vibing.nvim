-- Brand new file for testing diff on newly created files
-- This file should show up entirely as additions in the diff

local TestModule = {}

function TestModule.init()
  print("Initializing test module")
  return {
    name = "test",
    version = "1.0.0",
    ready = true,
  }
end

function TestModule.process(data)
  if not data then
    return nil
  end

  local result = {}
  for k, v in pairs(data) do
    result[k] = v * 2
  end

  return result
end

function TestModule.cleanup()
  print("Cleaning up test module")
end

return TestModule
