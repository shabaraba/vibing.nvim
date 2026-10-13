local function object(properties, required)
  return { type = "object", properties = properties, required = required, additionalProperties = false }
end

local string_value = { type = "string" }
local chat = object({ path = string_value, summary = string_value }, { "path", "summary" })
local group = object({ label = string_value, chats = { type = "array", items = chat } }, { "label", "chats" })

return object({ groups = { type = "array", items = group } }, { "groups" })
