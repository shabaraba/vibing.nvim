--- canUseTool implementation
--- Main permission evaluation logic for control_request handling
---
--- Permission evaluation order (highest to lowest priority):
--- 1. Session-level deny list (immediate block)
--- 2. Session-level allow list (auto-approve)
--- 3. Internal tools (always allowed, e.g. ToolSearch, Agent)
--- 3.5. bypassPermissions mode (bypasses deny list too)
--- 4. Deny list (deny takes precedence over allow)
--- 5. Always-allowed tools (bypass allow list; deny/ask still respected)
--- 6. Permission modes (auto, acceptEdits, default; dontAsk changes ask→deny below)
--- 7. Allow list (with pattern matching support)
--- 8. Ask list (granular patterns override broader allow list permissions)
--- 9. Granular permission rules (path/command/pattern/domain based)
---
--- @module vibing.infrastructure.permissions.can_use_tool

local matchers = require("vibing.infrastructure.permissions.matchers")
local rule_checker = require("vibing.infrastructure.permissions.rule_checker")
local tools_constants = require("vibing.core.constants.tools")

local M = {}

local ONCE_SUFFIX = ":once"

local INTERNAL_TOOLS = {
  ToolSearch = true,
  TodoWrite = true,
  Agent = true,
  Task = true,
  TaskCreate = true,
  TaskGet = true,
  TaskList = true,
  TaskOutput = true,
  TaskStop = true,
  TaskUpdate = true,
  SendMessage = true,
  Monitor = true,
  ScheduleWakeup = true,
  EnterPlanMode = true,
  ExitPlanMode = true,
  EnterWorktree = true,
  ExitWorktree = true,
  NotebookEdit = true,
}


--- @class CanUseToolResult
--- @field behavior "allow"|"deny"|"ask"
--- @field message? string
--- @field updated_input? table<string, any>

--- @class PermissionConfig
--- @field allowed_tools string[] Tools in allow list
--- @field denied_tools string[] Tools in deny list
--- @field asked_tools string[] Tools that require approval
--- @field session_allowed_tools string[] Session-level allowed tools (mutable)
--- @field session_denied_tools string[] Session-level denied tools (mutable)
--- @field permission_rules? PermissionRule[] Granular rules
--- @field permission_mode "default"|"acceptEdits"|"bypassPermissions"|"plan"|"dontAsk"|"auto"
--- @field mcp_enabled boolean

--- Check whether a tool name is a vibing-nvim MCP tool, regardless of how the MCP server was
--- registered (plain user-level server vs. Claude Code plugin — see the call site for details).
--- @param tool_name string
--- @param specific_tool? string Match only this vibing-nvim tool (e.g. "nvim_ask_user_question"); omit to match any vibing-nvim MCP tool
--- @return boolean
function M.is_vibing_nvim_mcp_tool(tool_name, specific_tool)
  local pattern = specific_tool and ("vibing%-nvim__" .. specific_tool .. "$") or "vibing%-nvim__nvim_[%w_]+$"
  return tool_name:match(pattern) ~= nil
end

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

    -- 3. Always allow Claude Code internal tools
    if INTERNAL_TOOLS[tool_name] then
      return allow(input)
    end

    local mode = config.permission_mode

    -- 3.5. bypassPermissions: truly bypass all operations including deny list
    if mode == "bypassPermissions" then
      return allow(input)
    end

    -- 4. Check deny list (deny takes precedence over allow)
    if config.denied_tools and #config.denied_tools > 0 then
      for _, pattern in ipairs(config.denied_tools) do
        if matchers.matches_permission(tool_name, input, pattern) then
          return deny(string.format("Tool %s is in the denied list", tool_name))
        end
      end
    end

    -- 5. Always-allowed tools: bypass allow list, but respect deny (checked above) and ask
    if tools_constants.ALWAYS_ALLOWED_TOOLS_MAP[tool_name] then
      for _, pattern in ipairs(config.asked_tools) do
        if matchers.matches_permission(tool_name, input, pattern) then
          if mode == "dontAsk" then
            return deny(string.format("Tool %s requires manual approval (not available in dontAsk mode)", tool_name))
          end
          return ask()
        end
      end
      return allow(input)
    end

    -- 6. Permission modes
    if mode == "auto" then
      return allow(input)
    end

    if mode == "acceptEdits" and (tool_name == "Edit" or tool_name == "Write") then
      return allow(input)
    end

    -- Handle vibing-nvim MCP tools. The vibing-nvim MCP server may be registered either as a
    -- plain user-level MCP server (mcp__vibing-nvim__<tool>) or as a Claude Code plugin
    -- (mcp__plugin_<marketplace>_<plugin>__<tool>, e.g. mcp__plugin_vibing-nvim_vibing-nvim__<tool>).
    -- Match on suffix so both registration styles are recognized identically.
    if M.is_vibing_nvim_mcp_tool(tool_name) then
      if config.mcp_enabled then
        return allow(input)
      end
      return deny("vibing.nvim MCP integration is disabled. Enable it in config: mcp.enabled = true")
    end

    -- 7. Check allow list (with pattern support)
    if #config.allowed_tools > 0 then
      local is_allowed = false
      for _, pattern in ipairs(config.allowed_tools) do
        if matchers.matches_permission(tool_name, input, pattern) then
          is_allowed = true
          break
        end
      end
      if not is_allowed then
        if mode == "dontAsk" then
          return deny(build_not_allowed_message(tool_name, input, config.allowed_tools))
        end
        return ask()
      end
    end

    -- 8. Check ask list (AFTER allow list - granular patterns override broader permissions)
    for _, pattern in ipairs(config.asked_tools) do
      if matchers.matches_permission(tool_name, input, pattern) then
        if mode == "dontAsk" then
          return deny(string.format("Tool %s requires manual approval (not available in dontAsk mode)", tool_name))
        end
        return ask()
      end
    end

    -- 9. Check granular permission rules
    if config.permission_rules and #config.permission_rules > 0 then
      local has_matching_allow = false
      for _, rule in ipairs(config.permission_rules) do
        local rule_result = rule_checker.check_rule(rule, tool_name, input)
        if rule_result == "deny" then
          return deny(rule.message or string.format("Tool %s is denied by permission rule", tool_name))
        elseif rule_result == "allow" then
          has_matching_allow = true
        end
      end
      if has_matching_allow then
        return allow(input)
      end
    end

    if mode == "dontAsk" then
      return deny(string.format("Tool %s is not pre-approved (dontAsk mode)", tool_name))
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
