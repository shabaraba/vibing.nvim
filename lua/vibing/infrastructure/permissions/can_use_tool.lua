--- canUseTool implementation
--- Main permission evaluation logic for control_request handling
---
--- Permission evaluation order (highest to lowest priority):
--- 1. Session-level deny list (immediate block)
--- 2. Session-level allow list (auto-approve)
--- 3. Permission modes (acceptEdits, default, bypassPermissions, plan, dontAsk)
--- 4. Allow list (with pattern matching support)
--- 5. Ask list (granular patterns override broader allow list permissions)
--- 6. Granular permission rules (path/command/pattern/domain based)
---
--- @module vibing.infrastructure.permissions.can_use_tool

local matchers = require("vibing.infrastructure.permissions.matchers")
local rule_checker = require("vibing.infrastructure.permissions.rule_checker")

local M = {}

local ONCE_SUFFIX = ":once"

--- @class CanUseToolResult
--- @field behavior "allow"|"deny"|"ask"
--- @field message? string
--- @field updated_input? table<string, any>

--- @class PermissionConfig
--- @field allowed_tools string[] Tools in allow list
--- @field asked_tools string[] Tools that require approval
--- @field session_allowed_tools string[] Session-level allowed tools (mutable)
--- @field session_denied_tools string[] Session-level denied tools (mutable)
--- @field permission_rules? PermissionRule[] Granular rules
--- @field permission_mode "default"|"acceptEdits"|"bypassPermissions"|"plan"|"dontAsk"
--- @field mcp_enabled boolean

--- Create allow result
--- @param input table<string, any>
--- @return CanUseToolResult
local function allow(input)
  return { behavior = "allow", updated_input = input }
end

--- Create deny result
--- @param message string
--- @return CanUseToolResult
local function deny(message)
  return { behavior = "deny", message = message }
end

--- Create ask result (request approval from user)
--- @return CanUseToolResult
local function ask()
  return { behavior = "ask" }
end

--- Check session permission list and handle one-time permissions
--- @param tool_name string
--- @param input table<string, any>
--- @param session_list string[]|nil
--- @param action "allow"|"deny"
--- @return CanUseToolResult|nil
local function check_session_list(tool_name, input, session_list, action)
  if not session_list or #session_list == 0 then
    return nil
  end

  for i = #session_list, 1, -1 do
    local item = session_list[i]
    local is_once = vim.endswith(item, ONCE_SUFFIX)
    local pattern = is_once and item:sub(1, -(#ONCE_SUFFIX + 1)) or item

    if matchers.matches_permission(tool_name, input, pattern) then
      if is_once then
        table.remove(session_list, i)
      end

      if action == "allow" then
        return allow(input)
      end
      local suffix = is_once and "once" or "for this session"
      return deny(string.format("Tool %s was denied %s.", tool_name, suffix))
    end
  end

  return nil
end

--- Build detailed "not allowed" message
--- @param tool_name string
--- @param input table<string, any>
--- @param allowed_tools string[]
--- @return string
local function build_not_allowed_message(tool_name, input, allowed_tools)
  local tool_lower = tool_name:lower()
  local tool_patterns = vim.tbl_filter(function(t)
    return vim.startswith(t:lower(), tool_lower .. "(")
  end, allowed_tools)

  if #tool_patterns == 0 then
    return string.format("Tool %s is not in the allowed list", tool_name)
  end

  local patterns = table.concat(
    vim.tbl_map(function(p)
      return "'" .. p .. "'"
    end, tool_patterns),
    ", "
  )

  if tool_lower == "bash" and input.command then
    return string.format(
      "Bash command '%s' does not match any allowed patterns. Allowed: %s",
      input.command,
      patterns
    )
  end
  if (tool_lower == "read" or tool_lower == "write" or tool_lower == "edit") and input.file_path then
    return string.format(
      "%s access to '%s' does not match any allowed patterns. Allowed: %s",
      tool_name,
      input.file_path,
      patterns
    )
  end
  if (tool_lower == "webfetch" or tool_lower == "websearch") and input.url then
    return string.format(
      "%s access to '%s' does not match any allowed patterns. Allowed: %s",
      tool_name,
      input.url,
      patterns
    )
  end
  if (tool_lower == "glob" or tool_lower == "grep") and input.pattern then
    return string.format(
      "%s pattern '%s' does not match any allowed patterns. Allowed: %s",
      tool_name,
      input.pattern,
      patterns
    )
  end

  return string.format("Tool %s is not in the allowed list", tool_name)
end

--- Evaluate tool permission
--- @param tool_name string
--- @param input table<string, any>
--- @param config PermissionConfig
--- @return CanUseToolResult
function M.can_use_tool(tool_name, input, config)
  local ok, result = pcall(function()
    -- 1. Session-level deny list (highest priority)
    local session_deny_result = check_session_list(tool_name, input, config.session_denied_tools, "deny")
    if session_deny_result then
      return session_deny_result
    end

    -- 2. Session-level allow list
    local session_allow_result = check_session_list(tool_name, input, config.session_allowed_tools, "allow")
    if session_allow_result then
      return session_allow_result
    end

    -- 3. Permission modes
    local mode = config.permission_mode

    if mode == "bypassPermissions" or mode == "dontAsk" then
      return allow(input)
    end

    if mode == "plan" then
      -- In plan mode, only allow read operations
      local read_only_tools = { "Read", "Glob", "Grep", "LSP", "WebFetch", "WebSearch" }
      if vim.tbl_contains(read_only_tools, tool_name) then
        return allow(input)
      end
      -- Also allow MCP read tools
      if tool_name:match("^mcp__") and not tool_name:match("set_") and not tool_name:match("write_") then
        return allow(input)
      end
      return ask()
    end

    if mode == "acceptEdits" and (tool_name == "Edit" or tool_name == "Write") then
      return allow(input)
    end

    if mode == "default" then
      local explicitly_allowed = false
      for _, pattern in ipairs(config.allowed_tools) do
        if matchers.matches_permission(tool_name, input, pattern) then
          explicitly_allowed = true
          break
        end
      end
      if not explicitly_allowed then
        return ask()
      end
    end

    -- Handle vibing-nvim MCP tools
    if vim.startswith(tool_name, "mcp__vibing-nvim__") then
      if config.mcp_enabled then
        return allow(input)
      end
      return deny("vibing.nvim MCP integration is disabled. Enable it in config: mcp.enabled = true")
    end

    -- 4. Check allow list (with pattern support)
    if #config.allowed_tools > 0 then
      local is_allowed = false
      for _, pattern in ipairs(config.allowed_tools) do
        if matchers.matches_permission(tool_name, input, pattern) then
          is_allowed = true
          break
        end
      end
      if not is_allowed then
        return deny(build_not_allowed_message(tool_name, input, config.allowed_tools))
      end
    end

    -- 5. Check ask list (AFTER allow list - granular patterns override broader permissions)
    for _, pattern in ipairs(config.asked_tools) do
      if matchers.matches_permission(tool_name, input, pattern) then
        return ask()
      end
    end

    -- 6. Check granular permission rules
    if config.permission_rules and #config.permission_rules > 0 then
      for _, rule in ipairs(config.permission_rules) do
        local rule_result = rule_checker.check_rule(rule, tool_name, input)
        if rule_result == "deny" then
          return deny(rule.message or string.format("Tool %s is denied by permission rule", tool_name))
        end
      end
    end

    return allow(input)
  end)

  if not ok then
    vim.notify(
      string.format("canUseTool failed: %s (tool: %s)", result, tool_name),
      vim.log.levels.ERROR
    )
    return deny(string.format("Permission check failed due to internal error: %s", result))
  end

  return result
end

--- Add tool to session allow list
--- @param session_allowed_tools string[]
--- @param tool_pattern string
--- @param once boolean
function M.add_session_allow(session_allowed_tools, tool_pattern, once)
  local pattern = once and (tool_pattern .. ONCE_SUFFIX) or tool_pattern
  table.insert(session_allowed_tools, pattern)
end

--- Add tool to session deny list
--- @param session_denied_tools string[]
--- @param tool_pattern string
--- @param once boolean
function M.add_session_deny(session_denied_tools, tool_pattern, once)
  local pattern = once and (tool_pattern .. ONCE_SUFFIX) or tool_pattern
  table.insert(session_denied_tools, pattern)
end

return M
