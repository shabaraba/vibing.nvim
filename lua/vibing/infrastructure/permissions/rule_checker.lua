--- Permission rule checker
--- Evaluates granular permission rules based on paths, commands, patterns, domains
--- @module vibing.infrastructure.permissions.rule_checker

local matchers = require("vibing.infrastructure.permissions.matchers")

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

--- @class PermissionRule
--- @field tools string[] Tools this rule applies to
--- @field paths? string[] Glob patterns for file paths
--- @field commands? string[] Allowed/denied command names
--- @field patterns? string[] Regex patterns for command matching
--- @field domains? string[] Domain patterns for web requests
--- @field action "allow"|"deny"
--- @field message? string Custom error message

--- Check if rule matches tool and input
--- @param rule PermissionRule
--- @param tool_name string
--- @param input table<string, any>
--- @return "allow"|"deny"|nil result "allow", "deny", or nil if rule doesn't apply
function M.check_rule(rule, tool_name, input)
  if not rule.tools or not vim.tbl_contains(rule.tools, tool_name) then
    return nil
  end

  if rule.paths and #rule.paths > 0 and input.file_path then
    local path_matches = false
    for _, pattern in ipairs(rule.paths) do
      if matchers.match_glob(pattern, input.file_path) then
        path_matches = true
        break
      end
    end
    if path_matches then
      return rule.action
    end
    return nil
  end

  if tool_name == "Bash" and input.command then
    local command_parts = vim.split(vim.trim(input.command), "%s+", { trimempty = true })
    local base_command = command_parts[1]

    if rule.commands and #rule.commands > 0 then
      local command_matches = vim.tbl_contains(rule.commands, base_command)
      if command_matches then
        return rule.action
      end
    end

    if rule.patterns and #rule.patterns > 0 then
      local pattern_matches = false
      for _, pattern in ipairs(rule.patterns) do
        local ok, result = pcall(function()
          if type(pattern) ~= "string" or #pattern > 500 then
            return false
          end
          return input.command:match(pattern) ~= nil
        end)
        if ok and result then
          pattern_matches = true
          break
        end
      end
      if pattern_matches then
        return rule.action
      end
    end

    if (rule.commands and #rule.commands > 0) or (rule.patterns and #rule.patterns > 0) then
      return nil
    end
  end

  if tool_name == "WebFetch" and input.url then
    if rule.domains and #rule.domains > 0 then
      local hostname = parse_url_hostname(input.url)
      if hostname then
        for _, domain in ipairs(rule.domains) do
          if matchers.match_glob(domain, hostname) then
            return rule.action
          end
        end
      end
      return nil
    end
  end

  return nil
end

return M
