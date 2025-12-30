---@class PermissionConfig
---@field allow string[]
---@field deny string[]
---@field rules PermissionRule[]?

---@class PermissionRule
---@field tools string[]
---@field paths string[]?
---@field commands string[]?
---@field patterns string[]?
---@field action "allow"|"deny"
---@field message string?

---@class PermissionContext
---@field path string?
---@field command string?

---@class EvaluationResult
---@field allowed boolean
---@field reason string?

---@class PermissionEvaluator
local M = {}

---Match a glob pattern against a path
---@param pattern string Glob pattern
---@param path string Path to match
---@return boolean
local function match_glob(pattern, path)
  -- Escape all Lua pattern special characters except * which we handle specially
  local regex = pattern:gsub("([%(%)%.%%%+%-%?%[%]%^%$])", "%%%1")
  regex = regex:gsub("%*%*", "___GLOBSTAR___")
  regex = regex:gsub("%*", "[^/]*")
  regex = regex:gsub("___GLOBSTAR___", ".*")
  regex = "^" .. regex .. "$"

  return path:match(regex) ~= nil
end

---Match a command against allowed commands
---@param allowed_commands string[] List of allowed commands
---@param command string Command to check
---@return boolean
local function match_command(allowed_commands, command)
  local cmd_name = command:match("^(%S+)")
  if not cmd_name then
    return false
  end

  for _, allowed in ipairs(allowed_commands) do
    if cmd_name == allowed then
      return true
    end
  end
  return false
end

---Match a command against patterns
---@param patterns string[] List of patterns
---@param command string Command to check
---@return boolean
local function match_pattern(patterns, command)
  for _, pattern in ipairs(patterns) do
    if command:match(pattern) then
      return true
    end
  end
  return false
end

---Check if a tool is in a list
---@param tool string Tool name
---@param list string[] List to check
---@return boolean
local function is_tool_in_list(tool, list)
  for _, t in ipairs(list) do
    if t == tool then
      return true
    end
  end
  return false
end

---Evaluate tool access based on allow/deny lists
---@param tool string Tool name
---@param context PermissionContext Context for evaluation
---@param config PermissionConfig Configuration
---@return EvaluationResult
function M.evaluate(tool, context, config)
  local allow_list = config.allow or {}
  local deny_list = config.deny or {}

  if is_tool_in_list(tool, deny_list) then
    return {
      allowed = false,
      reason = "Tool is in deny list: " .. tool,
    }
  end

  if #allow_list > 0 then
    if not is_tool_in_list(tool, allow_list) then
      return {
        allowed = false,
        reason = "Tool not in allow list: " .. tool,
      }
    end
  end

  return {
    allowed = true,
    reason = nil,
  }
end

---Check if a rule matches the given context
---@param rule PermissionRule Rule to check
---@param tool string Tool name
---@param context PermissionContext Context for evaluation
---@return boolean
local function matches_rule(rule, tool, context)
  if not is_tool_in_list(tool, rule.tools) then
    return false
  end

  local matched = false

  if rule.paths and context.path then
    for _, pattern in ipairs(rule.paths) do
      if match_glob(pattern, context.path) then
        matched = true
        break
      end
    end
  end

  if rule.patterns and context.command then
    if match_pattern(rule.patterns, context.command) then
      matched = true
    end
  end

  if rule.commands and context.command then
    if match_command(rule.commands, context.command) then
      matched = true
    end
  end

  return matched
end

---Evaluate tool access based on rules
---@param tool string Tool name
---@param context PermissionContext Context for evaluation
---@param rules PermissionRule[] List of rules
---@return EvaluationResult
function M.evaluate_with_rules(tool, context, rules)
  local deny_rules = {}
  local allow_rules = {}

  for _, rule in ipairs(rules) do
    if rule.action == "deny" then
      table.insert(deny_rules, rule)
    else
      table.insert(allow_rules, rule)
    end
  end

  for _, rule in ipairs(deny_rules) do
    if matches_rule(rule, tool, context) then
      return {
        allowed = false,
        reason = rule.message or "Denied by rule",
      }
    end
  end

  for _, rule in ipairs(allow_rules) do
    if matches_rule(rule, tool, context) then
      return {
        allowed = true,
        reason = nil,
      }
    end
  end

  return {
    allowed = false,
    reason = "No matching allow rule",
  }
end

---Create an evaluator instance
---@param config PermissionConfig Configuration
---@return {evaluate: fun(tool: string, context: PermissionContext): EvaluationResult}
function M.create_evaluator(config)
  return {
    evaluate = function(tool, context)
      if config.rules and #config.rules > 0 then
        return M.evaluate_with_rules(tool, context, config.rules)
      else
        return M.evaluate(tool, context, config)
      end
    end,
  }
end

return M
