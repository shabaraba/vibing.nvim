---@class Vibing.FrontmatterProvider
---Provider for YAML frontmatter completion items
---@module "vibing.infrastructure.completion.providers.frontmatter"
local tools_constants = require("vibing.core.constants.tools")

local M = {}

local Agents = require("vibing.core.constants.agents")
local ModelCatalog = require("vibing.infrastructure.adapter.models.catalog")

---Agent enum and per-agent model candidates both come from the backend registry, so adding a
---backend needs no edit here.
local AGENT_ENUM = vim.tbl_map(function(def)
  return { value = def.id, description = def.description }
end, Agents.list())

---Enum values for frontmatter fields
local ENUMS = {
  agent = AGENT_ENUM,
  effort = {
    { value = "default", description = "Use the selected CLI and model's default reasoning effort" },
    { value = "low", description = "Least reasoning, fastest and cheapest" },
    { value = "medium", description = "Moderate reasoning" },
    { value = "high", description = "More reasoning for intelligence-sensitive work" },
    { value = "xhigh", description = "Recommended for coding and agentic work" },
    { value = "max", description = "Most reasoning, slowest and most expensive" },
  },
  process = {
    { value = "oneshot", description = "One CLI process per turn (default)" },
    { value = "duplex", description = "One resident CLI process for the chat; faster turns, ~200MB while idle" },
  },
  profile = {
    { value = "default", description = "Ordinary chat: the full instruction block (default)" },
    { value = "worker", description = "Driven by another chat: drops instructions only a watching human needs" },
  },
  permission_mode = {
    { value = "default", description = "Ask for confirmation before each tool use" },
    { value = "acceptEdits", description = "Auto-approve Edit/Write, ask for others" },
    { value = "plan", description = "Read-only planning mode (no tool execution)" },
    { value = "auto", description = "Background safety classifier, minimal prompts" },
    { value = "dontAsk", description = "Deny instead of prompting (pre-approved tools only)" },
    { value = "bypassPermissions", description = "Auto-approve all operations (isolated env only)" },
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
  "mcp__chrome-devtools__*",
  "mcp__context7__*",
  "mcp__serena__*",
  "mcp__lapras__*",
}
vim.list_extend(TOOL_NAMES, tools_constants.VIBING_NVIM_MCP_TOOL_PATTERNS)

---Get enum values for a field
---@param field string Field name (agent, permission_mode, ...)
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

---Get model candidates for the given agent backend
---
---Through the catalogue rather than `Agents.models_for`: a backend whose CLI can be asked which
---models it has answers for itself, and the constant is what is offered until it does.
---@param agent string? "claude" | "codex" | "copilot" | "grok" (defaults to "claude")
---@return Vibing.CompletionItem[]
function M.get_model_values(agent)
  local models = ModelCatalog.candidates_for(agent)
  local items = {}
  for _, m in ipairs(models) do
    table.insert(items, {
      word = m.value,
      label = m.value,
      kind = "Enum",
      filterText = m.value,
      description = m.description,
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
