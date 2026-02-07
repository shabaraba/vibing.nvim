---@class Vibing.Infrastructure.SectionParser
---Abstract base class for section parsing strategies
---Platform-specific implementations (grep_parser, line_parser) implement this interface
---@field name string Parser implementation name ("grep_parser", "line_parser", etc.)
local SectionParser = {}
SectionParser.__index = SectionParser

---Create a SectionParser instance
---@return Vibing.Infrastructure.SectionParser
function SectionParser:new()
  local instance = setmetatable({}, self)
  instance.name = "base"
  return instance
end

---@class Vibing.Infrastructure.SectionParser.Message
---@field user string User message content
---@field assistant string Assistant response content
---@field timestamp string Message timestamp (YYYY-MM-DD HH:MM:SS)
---@field file string Source file path

---Extract messages for a specific date from a file
---Must be implemented by subclass (base class throws error)
---@param file_path string Path to chat file
---@param target_date string Target date (YYYY-MM-DD)
---@return Vibing.Infrastructure.SectionParser.Message[] messages
---@return string? error Error message (only on failure)
function SectionParser:extract_messages(file_path, target_date)
  error("extract_messages() must be implemented by subclass")
end

---Check if this Parser is available on the current platform
---Must be implemented by subclass (base class returns false)
---@return boolean supported True if supported
function SectionParser:supports_platform()
  return false
end

return SectionParser
