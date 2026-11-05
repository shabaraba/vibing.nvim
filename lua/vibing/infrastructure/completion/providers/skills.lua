---@class Vibing.SkillsProvider
---Skill candidates for the current chat's backend, from the sources its descriptor declares:
---a command probe of that CLI, its skill roots, and vibing's plugin skills where the backend
---receives them.
---@module "vibing.infrastructure.completion.providers.skills"
local M = {}

local ProbeCache = require("vibing.infrastructure.completion.providers.command_probe_cache")
local YamlFrontmatter = require("vibing.core.utils.yaml_frontmatter")

---Items per `agent + cwd`. A chat's `agent:` frontmatter can change mid-session, and two chats
---can name different backends, so one list cannot serve them all.
---@type table<string, Vibing.CompletionItem[]>
local _cache = {}

---Parse SKILL.md to extract name and description
---
---The description comes from frontmatter, the same key the CLI itself reports. This used to take
---the body's first `# heading` instead, which meant one `/` menu showed two different things
---depending only on where a skill happened to live -- and no amount of editing `description:`
---changed what a local skill displayed. The heading survives as a fallback for a skill that
---declares no description at all.
---
---This scan only fills gaps now: a skill the CLI already reported wins the dedup in
---`scan_skills`, so what is left is a directory the CLI declined or had not reloaded yet.
---@param file_path string
---@return {name: string, description: string}?
local function parse_skill(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  local lines = vim.fn.readfile(file_path, "", 50)
  if not lines or #lines == 0 then
    return nil
  end

  -- Skills are visible in the `/` menu unless they opt out, matching the CLI's own convention.
  if YamlFrontmatter.read(lines, "user-invocable") == "false" then
    return nil
  end

  local dir_name = vim.fn.fnamemodify(vim.fn.fnamemodify(file_path, ":h"), ":t")
  local description = YamlFrontmatter.read(lines, "description")

  if not description then
    for _, line in ipairs(lines) do
      local heading = line:match("^#%s+(.+)$")
      if heading then
        description = heading
        break
      end
    end
  end

  return { name = dir_name, description = description or dir_name }
end

---Exposed for tests: the callers above it walk real skill directories, so the parsing has no
---other reachable seam.
M._parse_skill = parse_skill

---The backend the current chat talks to, and the skill sources its descriptor declares.
---
---**This is what keeps the menu honest per backend.** The probe speaks one CLI's private
---protocol (Claude's), so asking it for every chat would offer `/design` to a Codex chat that
---cannot run it. A descriptor without `skill_sources` therefore contributes no skills at all —
---only vibing's own commands — rather than another backend's list.
---@return string agent
---@return Vibing.SkillSources sources
function M._sources()
  local ok, View = pcall(require, "vibing.presentation.chat.view")
  local chat = ok and View.get_current() or nil
  local frontmatter = chat and chat:parse_frontmatter() or nil
  local agent = require("vibing.core.constants.modes").resolve_agent(frontmatter, require("vibing.config").get())
  return agent, M._sources_for(agent)
end

---A backend's declared sources, without asking which chat is current.
---@param agent string
---@return Vibing.SkillSources
function M._sources_for(agent)
  local Agents = require("vibing.core.constants.agents")
  -- `get` falls back to the default backend, so an unknown id must be refused here rather than
  -- inheriting another backend's list.
  if not Agents.is_valid(agent) then
    return {}
  end
  local ok, descriptor = pcall(require, Agents.get(agent).descriptor_module)
  return (ok and descriptor.skill_sources) or {}
end

---`{path, source}` entries resolved against the editor's cwd.
---@param dirs {path: string, source: "project"|"user"}[]|nil
---@return {dir: string, source: "project"|"user"}[]
local function resolve_dirs(dirs)
  local cwd = vim.fn.getcwd(-1, -1)
  local out = {}
  for _, entry in ipairs(dirs or {}) do
    local path = entry.path
    if path:sub(1, 1) ~= "/" and not path:match("^~") then
      path = cwd .. "/" .. path
    end
    local resolved = (vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", ""))
    table.insert(out, { dir = resolved, source = entry.source })
  end
  return out
end

---Where a command came from, for the menu's second column.
---
---A plugin skill is namespaced in its own name (`vibing-nvim:vibing-code-tour`), which is also
---how it has to be typed. User and project skills carry a `(user)` / `(project)` marker the CLI
---appends to the description. Everything else is the CLI's own -- a built-in command or one of
---the skills bundled inside the binary. A probe that knows the answer (codex reports a scope per
---skill) says so in `source`, which wins over the description markers but not over a namespace.
---@param name string
---@param description string
---@param reported_source string?
---@return string source, string detail
local function classify(name, description, reported_source)
  local plugin = name:match("^([^:]+):")
  if plugin then
    return "plugin", plugin
  end
  if reported_source then
    return reported_source, reported_source
  end
  if description:match("%(user%)%s*$") then
    return "user", "user"
  end
  if description:match("%(project%)%s*$") then
    return "project", "project"
  end
  return "bundled", "bundled"
end

---Turn the CLI's command list into completion items.
---
---`hide` is the descriptor's list of commands that act on the CLI's interactive terminal session
---and so can do nothing from a chat buffer. They are dropped rather than shown, because the `/`
---menu is fuzzy-searched and inert entries make the real skills harder to find.
---@param commands Vibing.CliCommand[]
---@param hide string[]?
---@return Vibing.CompletionItem[]
local function to_items(commands, hide)
  local hidden = {}
  for _, name in ipairs(hide or {}) do
    hidden[name] = true
  end

  local items = {}
  for _, cmd in ipairs(commands) do
    local name = type(cmd) == "table" and cmd.name or nil
    -- A `__`-prefixed name is the CLI's own internal plumbing (`__remote-workflow`); it is not
    -- meant to be typed at all, which is why it is dropped rather than listed as terminal-only.
    if type(name) == "string" and name ~= "" and not name:match("^__") and not hidden[name] then
      local description = type(cmd.description) == "string" and cmd.description or ""
      local source, detail = classify(name, description, type(cmd.source) == "string" and cmd.source or nil)
      table.insert(items, {
        word = name,
        label = "/" .. name,
        kind = "Skill",
        description = description,
        detail = detail,
        source = source,
        filterText = name,
      })
    end
  end
  return items
end

M._to_items = to_items

---Start the background probe of this backend's command list. The item cache is dropped when the
---CLI answers, so the next completion sees the new entries.
---@param agent string
---@param sources Vibing.SkillSources
local function start_async_load(agent, sources)
  if sources.probe then
    ProbeCache.start(agent, sources.probe, function()
      _cache = {}
    end)
  end
end

---Drop the item cache when the cwd moved: project skills, project settings and `.vibing/plugins`
---are all resolved from it, so the previous answer describes another directory.
local function invalidate_if_stale()
  if ProbeCache.invalidate_if_stale() then
    _cache = {}
  end
end

---Commands the CLI reports for this directory.
---Returns the cached answer immediately; starts the probe if there is none yet.
---@param agent string
---@param sources Vibing.SkillSources
---@return Vibing.CompletionItem[]
local function get_cli_commands(agent, sources)
  if not sources.probe then
    return {}
  end
  local commands = ProbeCache.peek(agent)
  if commands then
    return to_items(commands, sources.probe.hide)
  end
  start_async_load(agent, sources)
  return {}
end

---One completion item per skill this backend can be asked for.
---@param agent string
---@param sources Vibing.SkillSources
---@return Vibing.CompletionItem[]
local function scan_skills(agent, sources)
  local items = {}

  -- Whose description wins the dedup below. A CLI that namespaces plugin skills and marks user and
  -- project ones (claude) is heard first -- the same skill, described the way the CLI describes
  -- it. One that only reports names (commandcode, codex) goes last: the directory scan knows
  -- where a skill lives, and the probe is there for the skills no directory holds.
  local probed = get_cli_commands(agent, sources)
  local authoritative = sources.probe ~= nil and sources.probe.authoritative == true
  if authoritative then
    vim.list_extend(items, probed)
  end

  for _, dir_info in ipairs(resolve_dirs(sources.dirs)) do
    if vim.fn.isdirectory(dir_info.dir) == 1 then
      -- Recursive: `~/.agents/skills` keeps installed skills under a `synced/<id>/<name>/`
      -- directory, so one level would silently miss most of what Command Code lists.
      local skill_files = vim.fn.glob(dir_info.dir .. "/**/SKILL.md", false, true)
      for _, skill_file in ipairs(skill_files) do
        local skill = parse_skill(skill_file)
        if skill then
          table.insert(items, {
            word = skill.name,
            label = "/" .. skill.name,
            kind = "Skill",
            description = skill.description,
            detail = dir_info.source,
            source = dir_info.source,
            filterText = skill.name,
          })
        end
      end
    end
  end

  -- Plugin skills are only listed where the backend actually receives them. Claude's probe
  -- already reports its namespaced copies, which is why its descriptor leaves this off.
  if sources.plugin_skills then
    local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
    local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
    local config = require("vibing.config").get()
    for _, entry in ipairs(PluginDirs.resolve_entries(vim.fn.getcwd(-1, -1), config)) do
      for _, skill in ipairs(PluginContents.skills(entry.path)) do
        table.insert(items, {
          word = skill.name,
          label = "/" .. skill.name,
          kind = "Skill",
          description = skill.description,
          detail = entry.name,
          source = "plugin",
          filterText = skill.name,
        })
      end
    end
  end

  if not authoritative then
    vim.list_extend(items, probed)
  end

  -- Deduplicate by word
  local seen = {}
  local deduped = {}
  for _, item in ipairs(items) do
    if not seen[item.word] then
      seen[item.word] = true
      table.insert(deduped, item)
    end
  end

  table.sort(deduped, function(a, b)
    return a.word < b.word
  end)

  return deduped
end

---Exposed for tests: which source wins a name is decided here, and the callers above it need a
---live chat buffer to know the current backend.
M._scan_skills = scan_skills

---Get all skill candidates for the current chat's backend (cached per agent + cwd)
---@return Vibing.CompletionItem[]
function M.get_all()
  invalidate_if_stale()
  local agent, sources = M._sources()
  local key = agent .. "\0" .. vim.fn.getcwd(-1, -1)
  if _cache[key] then
    return _cache[key]
  end
  local items = scan_skills(agent, sources)
  -- Only cache when the CLI probe is complete; avoid caching incomplete results
  if not M.is_preloading(sources, agent) then
    _cache[key] = items
  end
  return items
end

---The current chat's CLI command list **only if it has already been fetched**, never starting a
---probe.
---
---`get_all()` cannot answer this: it re-checks staleness, and a cwd that moved since the probe
---clears the cache and spawns a fresh CLI on the spot. A caller that is only looking one name up
----- `gd` on a word that may not be a command at all -- must not pay for that.
---@return Vibing.CompletionItem[]
function M.peek_cli_commands()
  invalidate_if_stale()
  local agent, sources = M._sources()
  local commands = sources.probe and ProbeCache.peek(agent)
  return commands and to_items(commands, sources.probe.hide) or {}
end

---Preload the current backend's command list in background (call at setup time to warm the cache)
function M.preload()
  invalidate_if_stale()
  local agent, sources = M._sources()
  start_async_load(agent, sources)
end

---Warm the probe for the backend a chat buffer's own frontmatter names.
---
---`preload()` can only warm the backend of whichever chat is current at that moment, and with one
---probe per backend that is no longer the backend of the chat being opened: a `commandcode` chat
---opened while a `claude` one was current would reach its first `/` with nothing probed, and show
---only the directory skills until the CLI answered. Called when a chat buffer is set up, so the
---answer is usually in by the time the user types.
---@param bufnr integer
function M.preload_buffer(bufnr)
  invalidate_if_stale()
  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  local frontmatter = Frontmatter.read(vim.api.nvim_buf_get_name(bufnr), bufnr)
  local agent = require("vibing.core.constants.modes").resolve_agent(frontmatter, require("vibing.config").get())
  start_async_load(agent, M._sources_for(agent))
end

---Check if the CLI's command list is still being fetched
---Returns false for a backend that has no probe, and true before the probe answers for one that
---does.
---@param sources Vibing.SkillSources|nil
---@param agent string|nil
---@return boolean
function M.is_preloading(sources, agent)
  if not sources or not agent then
    local current_agent, current_sources = M._sources()
    agent, sources = agent or current_agent, sources or current_sources
  end
  if not sources.probe then
    return false
  end
  return ProbeCache.is_loading(agent) or ProbeCache.peek(agent) == nil
end

---Clear cache (call when skills change)
function M.clear_cache()
  _cache = {}
  ProbeCache.clear()
end

return M
