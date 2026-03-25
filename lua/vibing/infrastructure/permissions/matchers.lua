--- Permission pattern matching functions
--- Handles glob patterns, bash commands, domains, and tool permission strings
--- @module vibing.infrastructure.permissions.matchers

local M = {}

--- Parse URL and extract hostname
--- @param url string
--- @return string|nil hostname
local function parse_url_hostname(url)
  if type(url) ~= "string" then
    return nil
  end
  local hostname = url:match("^https?://([^/:]+)")
  if hostname then
    return hostname:lower()
  end
  return nil
end

--- Simple glob pattern matching
--- @param pattern string Glob pattern (supports * and ?)
--- @param str string String to match against
--- @return boolean
function M.match_glob(pattern, str)
  if type(pattern) ~= "string" or type(str) ~= "string" then
    return false
  end

  if #pattern > 1000 then
    return false
  end

  local ok, result = pcall(function()
    local escaped = pattern:gsub("([%.%+%^%$%(%)%[%]%%])", "%%%1")
    local regex_pattern = escaped:gsub("%*", ".-"):gsub("%?", ".")
    return str:match("^" .. regex_pattern .. "$") ~= nil
  end)

  if not ok then
    return false
  end
  return result
end

--- @class ParsedToolPattern
--- @field tool_name string
--- @field rule_content string|nil
--- @field type "bash_wildcard"|"bash_exact"|"file_glob"|"domain_pattern"|"search_pattern"|"unknown_pattern"|"tool_name"

--- Parse tool permission string like "Tool(pattern)"
--- @param tool_str string
--- @return ParsedToolPattern
function M.parse_tool_pattern(tool_str)
  local tool_name, rule_content = tool_str:match("^([a-zA-Z]+)%((.+)%)$")

  if tool_name and rule_content then
    tool_name = tool_name:lower()

    if tool_name == "bash" then
      local is_wildcard = rule_content:match("^([^:]+):%*$")
      return {
        tool_name = "bash",
        rule_content = rule_content:lower(),
        type = is_wildcard and "bash_wildcard" or "bash_exact",
      }
    elseif tool_name == "read" or tool_name == "write" or tool_name == "edit" then
      return {
        tool_name = tool_name,
        rule_content = rule_content,
        type = "file_glob",
      }
    elseif tool_name == "webfetch" or tool_name == "websearch" then
      return {
        tool_name = tool_name,
        rule_content = rule_content:lower(),
        type = "domain_pattern",
      }
    elseif tool_name == "glob" or tool_name == "grep" then
      return {
        tool_name = tool_name,
        rule_content = rule_content,
        type = "search_pattern",
      }
    end

    return {
      tool_name = tool_name,
      rule_content = rule_content,
      type = "unknown_pattern",
    }
  end

  return {
    tool_name = tool_str:lower(),
    rule_content = nil,
    type = "tool_name",
  }
end

--- Match Bash command against permission pattern
--- @param command string
--- @param rule_content string
--- @param pattern_type "bash_wildcard"|"bash_exact"
--- @return boolean
function M.matches_bash_pattern(command, rule_content, pattern_type)
  local cmd = vim.trim(command):lower()
  local rule = rule_content:lower()

  if pattern_type == "bash_wildcard" then
    local base_pattern = rule:match("^([^:]+)")
    local cmd_parts = vim.split(cmd, "%s+", { trimempty = true })
    return cmd_parts[1] == base_pattern
  else
    return cmd == rule or vim.startswith(cmd, rule .. " ")
  end
end

--- Match file path against glob pattern
--- @param file_path string
--- @param glob_pattern string
--- @return boolean
function M.matches_file_glob(file_path, glob_pattern)
  return M.match_glob(glob_pattern, file_path)
end

--- Match URL domain against pattern
--- @param url string
--- @param domain_pattern string
--- @return boolean
function M.matches_domain_pattern(url, domain_pattern)
  local hostname = parse_url_hostname(url)
  if not hostname then
    return false
  end

  local pattern = domain_pattern:lower()

  if hostname == pattern then
    return true
  end

  if vim.startswith(pattern, "*.") then
    local base_domain = pattern:sub(3)
    return hostname == base_domain or vim.endswith(hostname, "." .. base_domain)
  end

  return false
end

--- Check if tool matches permission string (unified for all tools)
--- @param tool_name string
--- @param input table<string, any>
--- @param permission_str string
--- @return boolean
function M.matches_permission(tool_name, input, permission_str)
  local ok, result = pcall(function()
    local normalized_permission_str = permission_str:gsub(":once$", "")
    local parsed = M.parse_tool_pattern(normalized_permission_str)

    if parsed.type == "tool_name" then
      local perm_tool_name = parsed.tool_name
      local actual_tool_name = tool_name:lower()

      if vim.endswith(perm_tool_name, "*") then
        local prefix = perm_tool_name:sub(1, -2)
        return vim.startswith(actual_tool_name, prefix)
      end

      return actual_tool_name == perm_tool_name
    end

    if tool_name:lower() ~= parsed.tool_name then
      return false
    end

    if parsed.type == "bash_wildcard" or parsed.type == "bash_exact" then
      if input.command then
        return M.matches_bash_pattern(input.command, parsed.rule_content, parsed.type)
      end
      return false
    elseif parsed.type == "file_glob" then
      if input.file_path then
        return M.matches_file_glob(input.file_path, parsed.rule_content)
      end
      return false
    elseif parsed.type == "domain_pattern" then
      if input.url then
        return M.matches_domain_pattern(input.url, parsed.rule_content)
      end
      return false
    elseif parsed.type == "search_pattern" then
      if input.pattern then
        return input.pattern == parsed.rule_content
      end
      return false
    end

    return false
  end)

  if not ok then
    vim.notify(
      string.format("Permission matching failed for %s with pattern %s: %s", tool_name, permission_str, result),
      vim.log.levels.ERROR
    )
    return false
  end

  return result
end

return M
