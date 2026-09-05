--- Claude Code plugin directories loaded for the session via `--plugin-dir`.
---
--- vibing.nvim hosts its own bundled plugin (`claude-plugin/`) this way rather than installing
--- it into Claude Code's user scope, so the MCP server and the bundled skills always come from
--- the checkout that is running -- a worktree included. The same mechanism doubles as a
--- project-local personal plugin drop (`.vibing/plugins/*/`).
---
--- The resolved list is the single definition of "which plugin directories apply here": the CLI
--- argv (`cli_command_builder`, and `codex_plugin_config` for the backend that has no
--- `--plugin-dir`), the skill completion provider and the agent completion provider all read it,
--- rather than each re-deriving the convention.
--- @module vibing.infrastructure.plugins.plugin_dirs

local Notify = require("vibing.core.utils.notify")

local M = {}

--- @class Vibing.PluginDirEntry
--- @field name string plugin name, as declared by `.claude-plugin/plugin.json`
--- @field path string absolute path handed to `--plugin-dir`

--- Resolved entries per cwd. Keyed by the effective cwd, since `.vibing/plugins` is a
--- project-relative convention and a chat's `working_dir` can be a worktree.
---
--- The `config` argument is deliberately **not** part of the key: `setup()` runs before any
--- request, and every caller reads the same resolved config afterwards. A second `setup()` with
--- different `agent.plugins` therefore needs `clear_cache()` to take effect, which is also what
--- `:VibingReloadCommands` does.
--- @type table<string, Vibing.PluginDirEntry[]>
local cache = {}

--- vibing.nvim's own bundled plugin: `<repo>/claude-plugin`.
---
--- Resolved by walking up from this file to the `package.json` that marks the repo root, the
--- same way `completion/providers/skills.lua` finds `dist/`. The alternative in this codebase --
--- `debug.getinfo` plus a hand-counted `:h` chain -- encodes this file's own depth and breaks
--- silently if the module moves.
--- @return string|nil
local function self_plugin_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  local repo_root = vim.fs.root(source, "package.json")
  if not repo_root then
    return nil
  end
  return repo_root .. "/claude-plugin"
end

--- Read a candidate's plugin manifest.
---
--- `--plugin-dir` **silently ignores** a directory with no manifest, a malformed manifest, or a
--- path that does not exist -- measured against claude 2.1.231: every one of those completes the
--- turn with exit 0 and no warning. So a plugin that was dropped in and does not work leaves no
--- trace at all unless this checks first.
--- @param dir string
--- @return string|nil name, string|nil problem
local function read_manifest(dir)
  local manifest = dir .. "/.claude-plugin/plugin.json"
  if vim.fn.filereadable(manifest) ~= 1 then
    return nil, "no .claude-plugin/plugin.json"
  end

  local ok, lines = pcall(vim.fn.readfile, manifest)
  if not ok or type(lines) ~= "table" then
    return nil, "unreadable .claude-plugin/plugin.json"
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return nil, "malformed .claude-plugin/plugin.json"
  end

  if type(decoded.name) ~= "string" or decoded.name == "" then
    return nil, ".claude-plugin/plugin.json has no name"
  end

  return decoded.name, nil
end

--- Directories directly under `root .. "/" .. rel`, sorted, or `{}` when there are none.
---
--- A leading underscore means "present but not loaded". The scaffolded `_template` relies on it,
--- and it doubles as the way to park a plugin: renaming `my-plugin` to `_my-plugin` takes it out
--- of the session without deleting it. Since this resolution is what the skill and agent
--- completion providers read, an excluded directory disappears from the `/` picker too.
--- @param root string
--- @param rel string
--- @return string[]
local function glob_plugin_dirs(root, rel)
  local base = root .. "/" .. rel
  if vim.fn.isdirectory(base) ~= 1 then
    return {}
  end

  local found = vim.fn.glob(base .. "/*", false, true)
  local dirs = {}
  for _, path in ipairs(found) do
    if vim.fn.isdirectory(path) == 1 and not vim.fs.basename(path):match("^_") then
      table.insert(dirs, path)
    end
  end
  table.sort(dirs)
  return dirs
end

--- @param path string
--- @param base string
--- @return string
local function absolutise(path, base)
  if path:sub(1, 1) ~= "/" and not path:match("^~") then
    path = base .. "/" .. path
  end
  -- Parenthesised: gsub returns a replacement count as its second value, and letting that
  -- through turns the caller's `table.insert(dirs, absolutise(...))` into the three-argument
  -- positional form, which then rejects the path as a non-numeric index.
  return (vim.fn.fnamemodify(vim.fn.expand(path), ":p"):gsub("/$", ""))
end

--- The bundled plugin's directory, for a caller that has to tell it apart from a project plugin
--- of the same name -- by path, since the name is exactly what a look-alike would copy.
--- @return string|nil
function M.self_plugin_dir()
  local own = self_plugin_dir()
  return own and (vim.fn.fnamemodify(own, ":p"):gsub("/$", "")) or nil
end

--- Candidate directories in the order the CLI should see them.
---
--- **The order is load-bearing.** With two `--plugin-dir` paths declaring the same plugin name,
--- the earlier flag wins -- measured against claude 2.1.231 by giving each copy of a same-named
--- skill a different marker word and reading back which one the model saw. Putting `self` first
--- therefore means a project-local plugin cannot shadow vibing.nvim's own by reusing its name.
--- @param cwd string effective working directory of the request
--- @param nvim_root string
--- @param plugins table
--- @return string[]
local function candidates(cwd, nvim_root, plugins)
  local dirs = {}

  if plugins.self ~= false then
    local own = self_plugin_dir()
    if own then
      table.insert(dirs, own)
    end
  end

  local project_dir = plugins.project_dir
  if type(project_dir) == "string" and project_dir ~= "" then
    vim.list_extend(dirs, glob_plugin_dirs(cwd, project_dir))
    -- `.vibing/` is git-ignored, so a worktree checkout has no `.vibing/plugins` of its own.
    -- Also offer the root Neovim was started in, where the user actually puts them.
    --
    -- This is a union with per-name precedence, not the strict fallback
    -- `project_system_prompt.read_for_cwd` does for `.vibing/system-prompt.md`. That one picks a
    -- single file so it has to choose; a *set* of plugins does not. A worktree adding one
    -- experimental plugin should not lose every plugin the project already had, and the
    -- deduplication below still lets it override one of them by reusing its name.
    if cwd ~= nvim_root then
      vim.list_extend(dirs, glob_plugin_dirs(nvim_root, project_dir))
    end
  end

  for _, extra in ipairs(plugins.extra or {}) do
    if type(extra) == "string" and extra ~= "" then
      table.insert(dirs, absolutise(extra, cwd))
    end
  end

  return dirs
end

--- Resolve the plugin directories that apply to a request running in `cwd`.
---
--- Entries are deduplicated by plugin name, first occurrence winning, so the returned list
--- matches what the CLI actually loads rather than what it was offered.
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @param config Vibing.Config
--- @return Vibing.PluginDirEntry[]
function M.resolve_entries(cwd, config)
  -- The *global* cwd, not `getcwd()`. "The root Neovim was started in" is a property of the
  -- session, and `:lcd`/`:tcd` set a per-window view of it rather than a different project.
  -- Reading the window-local one would also disagree with the completion providers, which key
  -- their own caches on the global cwd: under `:lcd` the two would differ, `cwd ~= nvim_root`
  -- would hold spuriously, and `.vibing/plugins` would be globbed twice for the same project.
  local nvim_root = vim.fn.getcwd(-1, -1)
  local effective = (cwd and cwd ~= "") and cwd or nvim_root

  if cache[effective] then
    return cache[effective]
  end

  -- A non-table `agent.plugins` reads as "unset" rather than reaching `candidates()`, where
  -- `plugins.self` on a boolean or a string raises. The builder runs under `pcall`, so that
  -- surfaced as an unexplained "failed to build command" instead of naming the bad config.
  local plugins = config.agent and config.agent.plugins
  if type(plugins) ~= "table" then
    plugins = {}
  end
  local entries = {}
  local seen_names = {}
  local seen_paths = {}
  local problems = {}

  for _, dir in ipairs(candidates(effective, nvim_root, plugins)) do
    local path = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
    if not seen_paths[path] then
      seen_paths[path] = true
      local name, problem = read_manifest(path)
      if not name then
        table.insert(problems, string.format("%s (%s)", path, problem))
      elseif not seen_names[name] then
        seen_names[name] = true
        table.insert(entries, { name = name, path = path })
      end
    end
  end

  -- The cache above is what keeps this to one notification per cwd: resolution runs on every
  -- request, and warning each time would fire on every message. A separate warned-once flag
  -- would be redundant with it, and worse -- it would have to survive `clear_cache()` to mean
  -- anything, which would silence the warning on exactly the `:VibingReloadCommands` the user
  -- runs after trying to fix the plugin.
  if #problems > 0 then
    Notify.warn(
      "ignored by --plugin-dir, so their skills and MCP servers will not load: "
        .. table.concat(problems, ", "),
      "Plugins"
    )
  end

  cache[effective] = entries
  return entries
end

--- Absolute paths to pass to `--plugin-dir`, one flag each.
--- @param cwd string|nil the chat's `working_dir`; nil means Neovim's own cwd
--- @param config Vibing.Config
--- @return string[]
function M.resolve(cwd, config)
  local paths = {}
  for _, entry in ipairs(M.resolve_entries(cwd, config)) do
    table.insert(paths, entry.path)
  end
  return paths
end

--- Drop the resolved lists and the warned-about flags. Reached from
--- `:VibingReloadCommands`, which is how a newly dropped-in plugin becomes visible without
--- restarting Neovim.
function M.clear_cache()
  cache = {}
end

return M
