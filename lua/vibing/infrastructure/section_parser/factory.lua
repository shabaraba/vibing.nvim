---@class Vibing.Infrastructure.SectionParserFactory
---Factory for selecting optimal SectionParser based on platform

local M = {}

local GrepParser = require("vibing.infrastructure.section_parser.grep_parser")
local LineParser = require("vibing.infrastructure.section_parser.line_parser")

---@type Vibing.Infrastructure.SectionParser?
local cached_parser = nil

---Get optimal SectionParser for current platform
---@param force_fallback? boolean Force use of fallback (line_parser) for testing
---@return Vibing.Infrastructure.SectionParser
function M.get_parser(force_fallback)
  if cached_parser and not force_fallback then
    return cached_parser
  end

  if not force_fallback then
    local grep_parser = GrepParser:new()
    if grep_parser:supports_platform() then
      cached_parser = grep_parser
      return cached_parser
    end
  end

  cached_parser = LineParser:new()
  return cached_parser
end

---Reset cache (for testing)
function M.reset_cache()
  cached_parser = nil
end

---Get name of currently used Parser (for debug/logging)
---@return string? parser_name
function M.get_current_parser_name()
  if cached_parser then
    return cached_parser.name
  end
  return nil
end

return M
