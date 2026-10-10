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
--- `agent.profiles` is a list, one table per profile, each naming itself with `name`:
---   profiles = { { name = "implementer", model = "sonnet", tools = { ... } }, ... }
--- An entry whose `name` is a built-in (`default`, `worker`) extends that built-in field by field
--- instead of adding a profile. An entry that is not a table, or has no usable `name` (a non-empty
--- string of letters, digits, `_` and `-`), is ignored with a warning; when two entries share a
--- name the later one wins, also with a warning. A keyed table (`profiles = { worker = {...} }`)
--- is not read at all: each such key is ignored with a warning naming the list form.
---
--- Fields of a profile besides `name`, every one optional:
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

--- The built-ins, in the same shape as an `agent.profiles` entry.
--- @type Vibing.Profile[]
local BUILTIN = {
  { name = M.DEFAULT, description = "Ordinary chat: everything loaded", instructions = "full" },
  {
    name = M.WORKER,
    description = "Driven by another chat: drops instructions only a watching human needs",
    instructions = "worker",
  },
}

--- @type table<string, Vibing.Profile>
local BUILTIN_BY_NAME = {}
for _, entry in ipairs(BUILTIN) do
  BUILTIN_BY_NAME[entry.name] = entry
end

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

--- @param value any
--- @return boolean
local function is_name(value)
  return type(value) == "string" and value:match("^[%w_%-]+$") ~= nil
end

--- How a warning or an error names one field of the user's profile: the entry is found by its
--- `name`, not by its position in the list.
--- @param name string
--- @param field string
--- @return string
function M.field_label(name, field)
  return string.format('agent.profiles[name="%s"].%s', name, field)
end

--- The user's `agent.profiles` list, keyed by each entry's `name`. Entries that cannot be used
--- are skipped with a warning (see the module comment); a later duplicate replaces an earlier one.
--- @param config table|nil
--- @return table<string, table>
local function configured(config)
  local profiles = vim.tbl_get(config or {}, "agent", "profiles")
  if type(profiles) ~= "table" then
    return {}
  end

  for key in pairs(profiles) do
    if type(key) ~= "number" then
      warn_once(
        "keyed." .. tostring(key),
        string.format(
          'agent.profiles must be a list like { { name = "%s", ... } }; ignoring key "%s"',
          tostring(key),
          tostring(key)
        )
      )
    end
  end

  local by_name = {}
  for index = 1, table.maxn(profiles) do
    local entry = profiles[index]
    if type(entry) ~= "table" then
      warn_once("entry." .. index, string.format("agent.profiles[%d] is not a table; ignoring it", index))
    elseif not is_name(entry.name) then
      warn_once(
        "name." .. index,
        string.format(
          "agent.profiles[%d].name must be a non-empty string of letters, digits, _ or -; ignoring the entry",
          index
        )
      )
    else
      if by_name[entry.name] then
        warn_once(
          "duplicate." .. entry.name,
          string.format('agent.profiles has more than one entry named "%s"; using the last one', entry.name)
        )
      end
      by_name[entry.name] = entry
    end
  end
  return by_name
end

--- Every profile name a chat may use: the built-ins plus `agent.profiles`, sorted.
--- @param config table|nil
--- @return string[]
function M.names(config)
  local set = {}
  for name in pairs(BUILTIN_BY_NAME) do
    set[name] = true
  end
  for name in pairs(configured(config)) do
    set[name] = true
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
  local raw = vim.tbl_extend("force", {}, BUILTIN_BY_NAME[name] or {}, configured(config)[name] or {})
  local def = {}
  local function bad(field)
    warn_once(name .. "." .. field, M.field_label(name, field) .. " is invalid; ignoring it")
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
