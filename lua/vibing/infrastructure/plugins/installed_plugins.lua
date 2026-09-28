--- The plugins Claude Code installed, as `{ name, path }` -- the peer of `plugin_dirs`, which
--- answers for the ones vibing.nvim hands over itself with `--plugin-dir`.
---
--- Two layouts, both Claude Code's own: `marketplaces/<market>/plugins/<plugin>` and
--- `cache/<market>/<plugin>/<revision>`. They are stated here and nowhere else, so a layout that
--- changes under us is one edit rather than a hunt -- what each caller then does inside a root
--- (read `commands/`, `skills/`, the manifest) is its own business.
---
--- Globbed once per session: the tree is large and the answer is not. 62 roots and ~1500 paths
--- on the machine this was measured on -- 1.7ms to glob, against 0.2ms of `filereadable` over
--- the cached list. `:VibingReloadCommands` drops it.
--- @module vibing.infrastructure.plugins.installed_plugins

local M = {}

--- @class Vibing.InstalledPlugin
--- @field name string plugin name, as its directory spells it
--- @field path string absolute path of the plugin root

--- @type Vibing.InstalledPlugin[]|nil
local cache

--- @return Vibing.InstalledPlugin[]
function M.roots()
  if cache then
    return cache
  end

  local base = vim.fn.expand("~/.claude/plugins")
  local found = {}
  for _, path in ipairs(vim.fn.glob(base .. "/marketplaces/*/plugins/*", false, true)) do
    table.insert(found, { name = vim.fs.basename(path), path = path })
  end
  for _, path in ipairs(vim.fn.glob(base .. "/cache/*/*/*", false, true)) do
    -- Here the plugin name is the directory above the revision, not the root's own basename.
    table.insert(found, { name = vim.fs.basename(vim.fs.dirname(path)), path = path })
  end
  table.sort(found, function(a, b)
    return a.path < b.path
  end)

  cache = found
  return cache
end

--- Drop the list, so a plugin installed mid-session is reachable without restarting Neovim.
function M.clear_cache()
  cache = nil
end

return M
