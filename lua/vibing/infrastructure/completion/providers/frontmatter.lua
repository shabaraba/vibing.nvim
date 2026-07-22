---@class Vibing.FrontmatterProvider
---Provider for YAML frontmatter completion items
---@module "vibing.infrastructure.completion.providers.frontmatter"
local M = {}

local Modes = require("vibing.core.constants.modes")

---Descriptions for agent backend values (keys must match Modes.VALID_AGENTS)
local AGENT_DESCRIPTIONS = {
  claude = "Claude CLI (Anthropic)",
  codex = "Codex CLI (OpenAI)",
  grok = "Grok Build CLI (xAI)",
}

---Build agent enum entries from Modes.VALID_AGENTS so completion never drifts
---@return { value: string, description: string }[]
local function build_agent_enums()
  local items = {}
  for _, name in ipairs(Modes.VALID_AGENTS) do
    table.insert(items, {
      value = name,
      description = AGENT_DESCRIPTIONS[name] or name,
    })
  end
  return items
end

---Enum values for frontmatter fields
local ENUMS = {
  agent = build_agent_enums(),
  permissions_mode = {
    { value = "default", description = "Ask for confirmation before each tool use" },
    { value = "acceptEdits", description = "Auto-approve Edit/Write, ask for others" },
    { value = "plan", description = "Read-only planning mode (no tool execution)" },
    { value = "auto", description = "Background safety classifier, minimal prompts" },
    { value = "dontAsk", description = "Deny instead of prompting (pre-approved tools only)" },
    { value = "bypassPermissions", description = "Auto-approve all operations (isolated env only)" },
  },
}

---Model candidates per agent backend
local CLAUDE_MODELS = {
  { value = "haiku", description = "Claude Haiku (fastest)" },
  { value = "sonnet", description = "Claude Sonnet (balanced)" },
  { value = "opus", description = "Claude Opus (most capable)" },
  { value = "fable", description = "Claude Fable" },
}

local CODEX_MODELS = {
  { value = "gpt-5.5", description = "GPT-5.5 (default)" },
  { value = "gpt-5.4", description = "gpt-5.4" },
  { value = "gpt-5.4-mini", description = "GPT-5.4-Mini" },
  { value = "gpt-5.3-codex", description = "gpt-5.3-codex" },
  { value = "gpt-5.2", description = "gpt-5.2" },
}

local GROK_MODELS = {}
for _, name in ipairs(Modes.GROK_MODELS) do
  table.insert(GROK_MODELS, {
    value = name,
    description = name == Modes.GROK_MODELS[1] and (name .. " (default)") or name,
  })
end

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
  "mcp__plugin_vibing-nvim_vibing-nvim__*",
  "mcp__chrome-devtools__*",
  "mcp__context7__*",
  "mcp__serena__*",
  "mcp__lapras__*",
}

---Get enum values for a field
---@param field string Field name (agent, permissions_mode, ...)
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
---@param agent string? "claude" | "codex" | "grok" (defaults to "claude")
---@return Vibing.CompletionItem[]
function M.get_model_values(agent)
  local models = CLAUDE_MODELS
  if agent == "codex" then
    models = CODEX_MODELS
  elseif agent == "grok" then
    models = GROK_MODELS
  end
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
