local M = {}

local function match_glob(pattern, path)
  local regex = pattern:gsub("%.", "%%.")
  regex = regex:gsub("%*%*", "___GLOBSTAR___")
  regex = regex:gsub("%*", "[^/]*")
  regex = regex:gsub("___GLOBSTAR___", ".*")
  regex = "^" .. regex .. "$"

  return path:match(regex) ~= nil
end

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

local function match_pattern(patterns, command)
  for _, pattern in ipairs(patterns) do
    if command:match(pattern) then
      return true
    end
  end
  return false
end

local function is_tool_in_list(tool, list)
  for _, t in ipairs(list) do
    if t == tool then
      return true
    end
  end
  return false
end

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
    if is_tool_in_list(tool, rule.tools) then
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

      if matched then
        return {
          allowed = false,
          reason = rule.message or "Denied by rule",
        }
      end
    end
  end

  for _, rule in ipairs(allow_rules) do
    if is_tool_in_list(tool, rule.tools) then
      local matched = false

      if rule.paths and context.path then
        for _, pattern in ipairs(rule.paths) do
          if match_glob(pattern, context.path) then
            matched = true
            break
          end
        end
      end

      if rule.commands and context.command then
        if match_command(rule.commands, context.command) then
          matched = true
        end
      end

      if rule.patterns and context.command then
        if match_pattern(rule.patterns, context.command) then
          matched = true
        end
      end

      if matched then
        return {
          allowed = true,
          reason = nil,
        }
      end
    end
  end

  return {
    allowed = false,
    reason = "No matching allow rule",
  }
end

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
