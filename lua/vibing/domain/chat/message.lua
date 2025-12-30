---@class Message
---@field role string The role of the message sender (user, assistant, or system)
---@field content string The message content
---@field timestamp string The message timestamp in YYYY-MM-DD HH:MM:SS format
local Message = {}
Message.__index = Message

---@type table<string, boolean>
local VALID_ROLES = {
  user = true,
  assistant = true,
  system = true,
}

---@param str string
---@return string
local function capitalize(str)
  return str:sub(1, 1):upper() .. str:sub(2)
end

---@return string Timestamp in YYYY-MM-DD HH:MM:SS format
local function generate_timestamp()
  return os.date("%Y-%m-%d %H:%M:%S")
end

---Create a new Message instance
---@param role string The role (user, assistant, or system)
---@param content string The message content
---@param timestamp? string Optional timestamp, generated if not provided
---@return Message
function Message.new(role, content, timestamp)
  local self = setmetatable({}, Message)
  self.role = role
  self.content = content
  self.timestamp = timestamp or generate_timestamp()
  return self
end

---Validate the message
---@return boolean True if validation passes, raises error otherwise
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

---Format the message header
---@return string The formatted header line
function Message:to_header()
  local display_role = capitalize(self.role)
  return string.format("## %s %s", self.timestamp, display_role)
end

---Format the message as Markdown
---@return string The message formatted as Markdown
function Message:to_markdown()
  local header = self:to_header()
  return header .. "\n\n" .. self.content
end

---Parse a header line to extract role and timestamp
---@param header_line string The header line to parse
---@return {timestamp: string?, role: string}? Parsed header info or nil
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

---Check if a line is a header
---@param line string The line to check
---@return boolean True if the line is a header
function Message.is_header(line)
  return line:match("^## ") ~= nil
end

---Check if a line has a timestamp
---@param line string The line to check
---@return boolean True if the line has a timestamp
function Message.has_timestamp(line)
  return line:match("^## %d%d%d%d%-%d%d%-%d%d") ~= nil
end

return Message
