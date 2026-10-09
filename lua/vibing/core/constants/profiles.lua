--- What a chat is for, and therefore what it loads on every request (frontmatter `profile`).
---
--- Every request re-reads the whole fixed part of the prompt, so whatever a chat never uses is paid
--- for once per request for as long as the chat lives. A profile is a named answer to "what does
--- this kind of chat need": the built-in `default` loads everything, the built-in `worker` drops
--- only the instructions that need someone watching the editor, and `agent.profiles` in the user's
--- config can define more (an implementer that needs six tools and no project rules, a reviewer
--- on a different model, ...). Measured on claude 2.1.295 in this repository, a chat's floor is
--- ~67k tokens and a narrowed one ~11k: `handbook/architecture/orchestration.md`.
---
--- Fields of a profile, every one optional:
---   description      one line, shown to an orchestrator by `nvim_chat_list`
---   agent/model/effort  frontmatter for a chat `nvim_chat_create` makes on this profile
---   instructions     "full" | "worker" — vibing.nvim's own instruction block
---   tools            claude `--tools`: the built-in tools this chat may use. MCP tools are not
---                    affected, and `ToolSearch` is always added so they stay deferred: without it
---                    every MCP schema is loaded into the prompt instead (+14k measured)
---   setting_sources  claude `--setting-sources` for this chat; leaving out "project" drops the
---                    project's CLAUDE.md, rules, skills, agents and `.claude/settings.json`
---   context_files    files appended to the system prompt, the stand-in for what
---                    `setting_sources` left out (e.g. the three invariants an implementer needs)
---
--- **Which parts follow a switch is decided by the CLI, not here** (claude 2.1.295, measured):
--- the system prompt is recorded on a conversation's first request and replayed verbatim on every
--- resume (`--system-prompt-snapshot`), so `instructions` and `context_files` stay as they were at
--- the first message. `tools` and `setting_sources` are re-read per launch, and widening them takes
--- effect on the next message; narrowing them later does not shrink what the conversation already
--- loaded into its history. So `/profile default` on a worker gains the tools, rules and skills
--- immediately, which is the direction that is ever needed.
---
--- The `tools` / `setting_sources` / `context_files` fields are claude's; other backends ignore
--- them and honour `agent` / `model` / `effort` only.
--- @module vibing.core.constants.profiles
local M = {}

M.DEFAULT = "default"
M.WORKER = "worker"

M.INSTRUCTIONS = { "full", "worker" }

--- Always added to a `tools` list, see the module comment.
M.ALWAYS_TOOLS = { "ToolSearch" }

local VALID_SETTING_SOURCES = { user = true, project = true, ["local"] = true }

--- @type table<string, Vibing.Profile>
local BUILTIN = {
  [M.DEFAULT] = { description = "Ordinary chat: everything loaded", instructions = "full" },
  [M.WORKER] = {
    description = "Driven by another chat: drops instructions only a watching human needs",
    instructions = "worker",
  },
}

--- Each problem is reported once per Neovim session, not once per request.
local warned = {}

--- @param key string
--- @param message string
local function warn_once(key, message)
  if warned[key] then
    return
  end
  warned[key] = true
  require("vibing.core.utils.notify").warn(message, "Chat")
end

--- @param config table|nil
--- @return table<string, table>
local function configured(config)
  local profiles = vim.tbl_get(config or {}, "agent", "profiles")
  return type(profiles) == "table" and profiles or {}
end

--- @param value any
--- @return boolean
local function is_name(value)
  return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

--- Every profile name a chat may use: the built-ins plus `agent.profiles`, sorted.
--- @param config table|nil
--- @return string[]
function M.names(config)
  local set = { [M.DEFAULT] = true, [M.WORKER] = true }
  for name in pairs(configured(config)) do
    if is_name(name) then
      set[name] = true
    end
  end
  local names = vim.tbl_keys(set)
  table.sort(names)
  return names
end

--- @param profile any
--- @param config table|nil
--- @return boolean
function M.is_valid(profile, config)
  return is_name(profile) and vim.tbl_contains(M.names(config), profile)
end

--- @param list any
--- @return string[]|nil
local function string_list(list)
  if type(list) ~= "table" then
    return nil
  end
  local out = {}
  for _, item in ipairs(list) do
    if type(item) ~= "string" or item == "" or item:find("[,%c]") then
      return nil
    end
    table.insert(out, item)
  end
  return out
end

--- The definition a chat on `name` runs under, with every field checked. A field that is not
--- usable is dropped with a warning — never half-applied — so a typo loads *more*, not less.
--- @param name string
--- @param config table|nil
--- @return Vibing.Profile
local function definition(name, config)
  local raw = vim.tbl_extend("force", {}, BUILTIN[name] or {}, configured(config)[name] or {})
  local def = {}
  local function bad(field)
    warn_once(name .. "." .. field, string.format("agent.profiles.%s.%s is invalid; ignoring it", name, field))
  end

  for _, field in ipairs({ "description", "agent", "model", "effort" }) do
    local value = raw[field]
    if value ~= nil then
      if type(value) == "string" and value ~= "" and not value:find("%c") then
        def[field] = value
      else
        bad(field)
      end
    end
  end

  if raw.instructions ~= nil then
    if vim.tbl_contains(M.INSTRUCTIONS, raw.instructions) then
      def.instructions = raw.instructions
    else
      bad("instructions")
    end
  end

  if raw.tools ~= nil then
    local tools = string_list(raw.tools)
    if tools then
      for _, tool in ipairs(M.ALWAYS_TOOLS) do
        if not vim.tbl_contains(tools, tool) then
          table.insert(tools, tool)
        end
      end
      def.tools = tools
    else
      bad("tools")
    end
  end

  if raw.setting_sources ~= nil then
    local sources = string_list(raw.setting_sources)
    local ok = sources ~= nil
    for _, source in ipairs(sources or {}) do
      ok = ok and VALID_SETTING_SOURCES[source] == true
    end
    if ok then
      def.setting_sources = sources
    else
      bad("setting_sources")
    end
  end

  if raw.context_files ~= nil then
    local files = string_list(raw.context_files)
    if files then
      def.context_files = files
    else
      bad("context_files")
    end
  end

  def.instructions = def.instructions or "full"
  return def
end

--- The profile a request runs under. A missing value is `default`; an unknown name warns once and
--- is treated as `default`, because the safe failure is the chat that loads *more*.
--- @param profile any frontmatter `profile`
--- @param config table|nil plugin config (`agent.profiles`)
--- @return string name
--- @return Vibing.Profile definition
function M.resolve(profile, config)
  if profile == nil or profile == vim.NIL or profile == "" then
    return M.DEFAULT, definition(M.DEFAULT, config)
  end
  if M.is_valid(profile, config) then
    return profile, definition(profile, config)
  end
  warn_once(
    "unknown." .. tostring(profile),
    string.format("Ignoring unknown profile %s (valid: %s)", tostring(profile), table.concat(M.names(config), ", "))
  )
  return M.DEFAULT, definition(M.DEFAULT, config)
end

--- What an orchestrator is shown by `nvim_chat_list`: each profile's name, description and the
--- model a chat created on it gets.
--- @param config table|nil
--- @return {name: string, description: string?, agent: string?, model: string?, effort: string?}[]
function M.catalog(config)
  local out = {}
  for _, name in ipairs(M.names(config)) do
    local def = definition(name, config)
    table.insert(out, {
      name = name,
      description = def.description,
      agent = def.agent,
      model = def.model,
      effort = def.effort,
    })
  end
  return out
end

--- Test seam: forget which warnings were already shown.
function M._reset_warnings()
  warned = {}
end

return M
