-- Test file v3 for new file diff verification
-- This should show up in Modified Files after creation

local TestV3 = {}

function TestV3.run()
  print("Running test v3")
  return {
    status = "ok",
    timestamp = os.time(),
  }
end

function TestV3.validate(data)
  if not data or type(data) ~= "table" then
    return false, "Invalid data type"
  end

  if not data.status then
    return false, "Missing status field"
  end

  return true, "Validation passed"
end

return TestV3
