local Message = {}
Message.__index = Message

local VALID_ROLES = {
  user = true,
  assistant = true,
  system = true,
}

local function capitalize(str)
  return str:sub(1, 1):upper() .. str:sub(2)
end

local function generate_timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

function Message.new(role, content, timestamp)
  local self = setmetatable({}, Message)
  self.role = role
  self.content = content
  self.timestamp = timestamp or generate_timestamp()
  return self
end

function Message:validate()
  if self.role == nil or self.role == "" then
    error("Role cannot be nil or empty")
  end

  if not VALID_ROLES[self.role] then
    error("Invalid role: " .. tostring(self.role))
  end

  if type(self.content) ~= "string" then
    error("Content must be a string")
  end

  return true
end

function Message:to_header()
  local display_role = capitalize(self.role)
  return string.format("## %s %s", self.timestamp, display_role)
end

function Message:to_markdown()
  local header = self:to_header()
  return header .. "\n\n" .. self.content
end

function Message.from_header(header_line)
  local timestamp, role = header_line:match("^## (%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d) (%w+)$")

  if timestamp and role then
    return {
      timestamp = timestamp,
      role = role:lower(),
    }
  end

  local legacy_role = header_line:match("^## (%w+)$")
  if legacy_role then
    return {
      timestamp = nil,
      role = legacy_role:lower(),
    }
  end

  return nil
end

function Message.is_header(line)
  return line:match("^## ") ~= nil
end

function Message.has_timestamp(line)
  return line:match("^## %d%d%d%d%-%d%d%-%d%d") ~= nil
end

return Message
