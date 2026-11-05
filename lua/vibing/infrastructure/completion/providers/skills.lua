---@class Vibing.SkillsProvider
---Skill candidates for the current chat's backend, from the sources its descriptor declares:
---Claude's own command probe, that CLI's skill roots, and vibing's plugin skills where the
---backend receives them.
---@module "vibing.infrastructure.completion.providers.skills"
local M = {}

local CliCommandList = require("vibing.infrastructure.completion.cli_command_list")
local YamlFrontmatter = require("vibing.core.utils.yaml_frontmatter")

---Items per `agent + cwd`. A chat's `agent:` frontmatter can change mid-session, and two chats
---can name different backends, so one list cannot serve them all.
---@type table<string, Vibing.CompletionItem[]>
local _cache = {}

---@type Vibing.CompletionItem[]?
local _cli_cache = nil

---@type boolean
local _loading = false

---@type integer
local _load_generation = 0

---@type string?
local _cli_cache_cwd = nil

---Loop time (ms) before which a new probe must not start.
---
---Nothing is cached when the probe fails, and `get_all()` is on the completion path -- so without
---this, a CLI that answers wrongly (or not at all) would have a fresh `claude` spawned per
---keystroke, each living until its own timeout. The retry is deliberately kept, just rate-limited:
---the usual failure is transient, and giving up until `:VibingReloadCommands` would leave the `/`
---menu quietly missing every skill.
---@type number
local _retry_after = 0

---@type integer
local FAILURE_COOLDOWN_MS = 30000

---Commands the CLI offers that act on its interactive terminal session, and so cannot do
---anything from a chat buffer. They are dropped rather than shown, because the `/` menu is
---fuzzy-searched and a third of it being inert entries makes the real skills harder to find.
---
---This is a denylist, and the difference from the allowlist it replaces is the whole point:
---when the CLI grows a command nobody here has heard of, a stale allowlist hides it (which is
---how `/design`, `/dataviz` and `/code-review` were missing) while a stale denylist merely shows
---one extra entry.
---@type table<string, boolean>
local TERMINAL_ONLY_COMMANDS = {
  agents = true,
  ["auto-mode-setup"] = true,
  autocompact = true,
  color = true,
  config = true,
  ["extra-usage"] = true,
  fast = true,
  heapdump = true,
  import = true,
  insights = true,
  ["list-agents"] = true,
  mcp = true,
  recap = true,
  ["reload-skills"] = true,
  rename = true,
  ["team-onboarding"] = true,
  usage = true,
  ["usage-credits"] = true,
  ["workflow-launch-exec"] = true,
}

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

---Plugin directories vibing.nvim self-hosts via `--plugin-dir`. The CLI is asked for its command
---list with the very same flags a chat gets, so their skills are namespaced and reported by the
---CLI itself rather than being rediscovered here.
---
---Resolved against the same global cwd the rest of this module keys on, not a chat's
---`working_dir`: completion is a property of the editor, not of whichever chat buffer happens to
---be focused. Passing it explicitly is what lets `_cli_cache_cwd` stand in as this list's
---staleness key too -- `plugin_dirs` caches per cwd, so with the cwd unchanged the list cannot
---change underneath us except via `plugin_dirs.clear_cache()`, and the only caller of that
---(`:VibingReloadCommands`) clears this module's cache in the same breath.
---@return string[]
local function resolve_plugin_dirs()
  local ok, PluginDirs = pcall(require, "vibing.infrastructure.plugins.plugin_dirs")
  if not ok then
    return {}
  end
  local config_ok, Config = pcall(require, "vibing.config")
  if not config_ok then
    return {}
  end
  return PluginDirs.resolve(vim.fn.getcwd(-1, -1), Config.get())
end

---Where a command came from, for the menu's second column.
---
---A plugin skill is namespaced in its own name (`vibing-nvim:vibing-code-tour`), which is also
---how it has to be typed. User and project skills carry a `(user)` / `(project)` marker the CLI
---appends to the description. Everything else is the CLI's own -- a built-in command or one of
---the skills bundled inside the binary.
---@param name string
---@param description string
---@return string source, string detail
local function classify(name, description)
  local plugin = name:match("^([^:]+):")
  if plugin then
    return "plugin", plugin
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
---@param commands Vibing.CliCommand[]
---@return Vibing.CompletionItem[]
local function to_items(commands)
  local items = {}
  for _, cmd in ipairs(commands) do
    local name = type(cmd) == "table" and cmd.name or nil
    -- A `__`-prefixed name is the CLI's own internal plumbing (`__remote-workflow`); it is not
    -- meant to be typed at all, which is why it is dropped rather than listed as terminal-only.
    if
      type(name) == "string"
      and name ~= ""
      and not name:match("^__")
      and not TERMINAL_ONLY_COMMANDS[name]
    then
      local description = type(cmd.description) == "string" and cmd.description or ""
      local source, detail = classify(name, description)
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

---Start the background probe of the CLI's command list.
---Sets _cli_cache when it answers and invalidates _cache.
---@param sources Vibing.SkillSources
local function start_async_load(sources)
  if not sources.probe or _loading or _cli_cache or vim.uv.now() < _retry_after then
    return
  end

  local config_ok, Config = pcall(require, "vibing.config")
  if not config_ok then
    return
  end

  local cwd = vim.fn.getcwd(-1, -1)
  local load_generation = _load_generation
  _loading = true
  _cli_cache_cwd = cwd

  local started = CliCommandList.fetch({
    cwd = cwd,
    config = Config.get(),
    plugin_dirs = resolve_plugin_dirs(),
  }, function(commands)
    if load_generation ~= _load_generation then
      return
    end
    _loading = false
    -- Nothing is cached on failure, so a later completion trigger retries. Same for a cwd that
    -- moved while the probe was in flight -- the answer describes the directory it was asked in.
    if not commands or vim.fn.getcwd(-1, -1) ~= cwd then
      _retry_after = vim.uv.now() + FAILURE_COOLDOWN_MS
      return
    end
    _cli_cache = to_items(commands)
    _cache = {}
  end)

  if not started then
    _loading = false
    _cli_cache_cwd = nil
    _retry_after = vim.uv.now() + FAILURE_COOLDOWN_MS
  end
end

---Invalidate the CLI/top-level caches when the cwd moved: project skills, project settings and
---`.vibing/plugins` are all resolved from it, so the previous answer describes another directory.
local function invalidate_if_stale()
  -- A nil cwd means no probe has ever been started, which is not staleness: bumping the
  -- generation here would cancel the one `preload()` fires a moment before the first `/`.
  if _cli_cache_cwd == nil or _cli_cache_cwd == vim.fn.getcwd(-1, -1) then
    return
  end

  _cli_cache = nil
  _cli_cache_cwd = nil
  _loading = false
  _load_generation = _load_generation + 1
  _cache = {}
  -- A new directory is a different question, so it does not wait out the old one's cooldown.
  _retry_after = 0
end

---Commands the CLI reports for this directory.
---Returns the cached answer immediately; starts the probe if there is none yet.
---@param sources Vibing.SkillSources
---@return Vibing.CompletionItem[]
local function get_cli_commands(sources)
  if not sources.probe then
    return {}
  end
  if _cli_cache then
    return _cli_cache
  end
  start_async_load(sources)
  return {}
end

---One completion item per skill this backend can be asked for.
---@param sources Vibing.SkillSources
---@return Vibing.CompletionItem[]
local function scan_skills(sources)
  local items = {}

  -- The CLI's own answer goes first, so its description and namespacing win the dedup below
  -- over the directory scan's -- the same skill, described the way the CLI describes it.
  for _, skill in ipairs(get_cli_commands(sources)) do
    table.insert(items, skill)
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

---Get all skill candidates for the current chat's backend (cached per agent + cwd)
---@return Vibing.CompletionItem[]
function M.get_all()
  invalidate_if_stale()
  local agent, sources = M._sources()
  local key = agent .. "\0" .. vim.fn.getcwd(-1, -1)
  if _cache[key] then
    return _cache[key]
  end
  local items = scan_skills(sources)
  -- Only cache when the CLI probe is complete; avoid caching incomplete results
  if not M.is_preloading(sources) then
    _cache[key] = items
  end
  return items
end

---The CLI's command list **only if it has already been fetched**, never starting a probe.
---
---`get_all()` cannot answer this: it re-checks staleness, and a cwd that moved since the probe
---clears the cache and spawns a fresh `claude` on the spot. A caller that is only looking one
---name up -- `gd` on a word that may not be a command at all -- must not pay for that.
---@return Vibing.CompletionItem[]
function M.peek_cli_commands()
  invalidate_if_stale()
  return _cli_cache or {}
end

---Preload the current backend's command list in background (call at setup time to warm the cache)
function M.preload()
  invalidate_if_stale()
  local _, sources = M._sources()
  start_async_load(sources)
end

---Check if the CLI's command list is still being fetched
---Returns false for a backend that has no probe, and true before the probe answers for one that
---does.
---@param sources Vibing.SkillSources|nil
---@return boolean
function M.is_preloading(sources)
  sources = sources or select(2, M._sources())
  if not sources.probe then
    return false
  end
  return _loading or _cli_cache == nil
end

---Clear cache (call when skills change)
function M.clear_cache()
  _load_generation = _load_generation + 1
  _cache = {}
  _cli_cache = nil
  _cli_cache_cwd = nil
  _loading = false
  -- `:VibingReloadCommands` is the user asking for a retry now, cooldown or not.
  _retry_after = 0
end

return M
