---@class Vibing.FrontmatterProvider
---Provider for YAML frontmatter completion items
---@module "vibing.infrastructure.completion.providers.frontmatter"
local M = {}

---Enum values for frontmatter fields
local ENUMS = {
  mode = {
    { value = "auto", description = "Automatic mode selection" },
    { value = "plan", description = "Planning mode (design before implementation)" },
    { value = "code", description = "Code implementation mode" },
    { value = "explore", description = "Exploration mode (codebase understanding)" },
  },
  model = {
    { value = "sonnet", description = "Claude Sonnet (balanced)" },
    { value = "opus", description = "Claude Opus (most capable)" },
    { value = "haiku", description = "Claude Haiku (fastest)" },
  },
  permissions_mode = {
    { value = "default", description = "Ask for confirmation before each tool use" },
    { value = "acceptEdits", description = "Auto-approve Edit/Write, ask for others" },
    { value = "bypassPermissions", description = "Auto-approve all operations" },
  },
}

---Available tool names for permissions lists
local TOOL_NAMES = {
  "Read",
  "Edit",
  "Write",
  "Bash",
  "Bash(",  -- Pattern-enabled variant
  "Glob",
  "Grep",
  "WebSearch",
  "WebFetch",
  "Skill",
  "mcp__vibing-nvim__*",
  "mcp__chrome-devtools__*",
  "mcp__context7__*",
  "mcp__serena__*",
  "mcp__lapras__*",
}

---Get enum values for a field
---@param field string Field name (mode, model, permissions_mode)
---@return Vibing.CompletionItem[]
function M.get_enum_values(field)
  local values = ENUMS[field]
  if not values then
    return {}
  end

  local items = {}
  for _, enum_item in ipairs(values) do
    table.insert(items, {
      word = enum_item.value,
      label = enum_item.value,
      kind = "Enum",
      filterText = enum_item.value,
      description = enum_item.description,
    })
  end

  return items
end

---Get tool names for permissions lists
---@return Vibing.CompletionItem[]
function M.get_tool_names()
  local items = {}
  for _, tool in ipairs(TOOL_NAMES) do
    local description = "Permission tool: " .. tool
    if tool == "Bash(" then
      description = "Bash with command pattern (e.g., Bash(rm:*))"
    end
    table.insert(items, {
      word = tool,
      label = tool,
      kind = "Tool",
      filterText = tool,
      description = description,
    })
  end
  return items
end

---Common command patterns for Bash tool
local BASH_PATTERNS = {
  { pattern = "rm:*", description = "Remove commands (rm, rm -rf, etc.)" },
  { pattern = "sudo:*", description = "Sudo commands" },
  { pattern = "dd:*", description = "dd commands" },
  { pattern = "mkfs:*", description = "Filesystem creation commands" },
  { pattern = "chmod:*", description = "Permission change commands" },
  { pattern = "chown:*", description = "Ownership change commands" },
  { pattern = "curl:*", description = "curl commands" },
  { pattern = "wget:*", description = "wget commands" },
  { pattern = "git:*", description = "git commands" },
  { pattern = "npm:*", description = "npm commands" },
  { pattern = "yarn:*", description = "yarn commands" },
}

---Get command patterns for tools like Bash(pattern)
---@param tool_name string Tool name (e.g., "Bash")
---@return Vibing.CompletionItem[]
function M.get_command_patterns(tool_name)
  if tool_name ~= "Bash" then
    return {}
  end

  local items = {}
  for _, pattern_item in ipairs(BASH_PATTERNS) do
    table.insert(items, {
      word = pattern_item.pattern,
      label = pattern_item.pattern,
      kind = "Pattern",
      filterText = pattern_item.pattern,
      description = pattern_item.description,
    })
  end
  return items
end

---Check if a tool supports command patterns
---@param tool_name string Tool name (e.g., "Bash")
---@return boolean
function M.has_command_patterns(tool_name)
  return tool_name == "Bash"
end

return M
