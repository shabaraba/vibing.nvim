--- What a plugin directory contains, read for a backend that cannot load the directory itself.
---
--- `plugin_dirs` decides *which* directories apply to a request; the claude CLI then reads each
--- one through `--plugin-dir` and vibing.nvim never looks inside. Codex has no such flag
--- (`handbook/architecture/plugin-and-commands.md` → "Codex"), so for it the two halves a plugin
--- carries -- its MCP servers and its skills -- have to be read here and handed over separately.
--- This module only reads; how each half reaches a CLI is the adapter's business.
---
--- The manifest is `.claude-plugin/plugin.json`, the same one `plugin_dirs` validates. Codex's own
--- plugin format (`.codex-plugin/plugin.json`) is not read: a directory carrying only that
--- manifest is dropped by `plugin_dirs` before this module sees it, and codex 0.153 itself
--- accepts `.claude-plugin/plugin.json` as a plugin manifest, so the claude form is the one
--- both CLIs understand.
--- @module vibing.infrastructure.plugins.plugin_contents

local YamlFrontmatter = require("vibing.core.utils.yaml_frontmatter")

local M = {}

--- @class Vibing.PluginMcpServer
--- @field name string key under `mcpServers`
--- @field command string|nil executable, for a stdio server
--- @field args string[] arguments, for a stdio server
--- @field env table<string, string> extra environment, for a stdio server
--- @field url string|nil endpoint, for a streamable HTTP server

--- @class Vibing.PluginSkill
--- @field name string frontmatter `name`, or the directory name when absent
--- @field description string frontmatter `description`, or "" when absent
--- @field path string absolute path of the SKILL.md

--- The one substitution Claude Code performs in a plugin manifest.
local PLUGIN_ROOT_VAR = "${CLAUDE_PLUGIN_ROOT}"

--- @param path string
--- @return table|nil
local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

--- Substitute `${CLAUDE_PLUGIN_ROOT}` throughout a manifest value.
---
--- Claude Code expands it in `command`, `args` and `env` alike, so this walks strings inside
--- tables rather than special-casing the three fields. `vim.NIL` (JSON null) is returned as is
--- and filtered by the caller.
--- @param value any
--- @param root string
--- @return any
local function expand(value, root)
  if type(value) == "string" then
    -- The replacement is a function, not `root` itself: a string replacement has `gsub` read
    -- `%` in it as an escape, so a plugin under a directory whose path contains one (a branch
    -- name with a URL-encoded character, say) errored on every manifest read -- for every
    -- plugin, `${CLAUDE_PLUGIN_ROOT}` or not, since every string value passes through here.
    return (value:gsub(PLUGIN_ROOT_VAR:gsub("%p", "%%%0"), function()
      return root
    end))
  end
  if type(value) == "table" then
    local out = {}
    for k, v in pairs(value) do
      out[k] = expand(v, root)
    end
    return out
  end
  return value
end

--- @param path string
--- @param root string
--- @return string
local function absolutise(path, root)
  if path:sub(1, 1) == "/" then
    return path
  end
  return root .. "/" .. path:gsub("^%./", "")
end

--- Only the string-valued entries of a JSON object, so a manifest that puts a number or a null
--- in `env` cannot reach the argv.
--- @param map any
--- @return table<string, string>
local function string_map(map)
  local out = {}
  if type(map) == "table" then
    for k, v in pairs(map) do
      if type(k) == "string" and type(v) == "string" then
        out[k] = v
      end
    end
  end
  return out
end

--- @param list any
--- @return string[]
local function string_list(list)
  local out = {}
  if type(list) == "table" then
    for _, v in ipairs(list) do
      if type(v) == "string" then
        table.insert(out, v)
      end
    end
  end
  return out
end

--- The MCP servers a plugin declares, sorted by name.
---
--- `mcpServers` is either the map itself or a path to a JSON file holding it (Claude Code's
--- `"mcpServers": "./.mcp.json"` form, resolved against the plugin root). Both `{"mcpServers":
--- {...}}` and a bare map are accepted in that file, since `.mcp.json` uses the wrapper and a
--- hand-written one may not. A server with neither `command` nor `url` is dropped: there is
--- nothing to start.
--- @param plugin_dir string absolute path of the plugin
--- @return Vibing.PluginMcpServer[]
function M.mcp_servers(plugin_dir)
  local manifest = read_json(plugin_dir .. "/.claude-plugin/plugin.json")
  if not manifest then
    return {}
  end

  local servers = manifest.mcpServers
  if type(servers) == "string" then
    local file = read_json(absolutise(expand(servers, plugin_dir), plugin_dir))
    servers = file and (type(file.mcpServers) == "table" and file.mcpServers or file) or nil
  end
  if type(servers) ~= "table" then
    return {}
  end

  local result = {}
  for name, spec in pairs(servers) do
    if type(name) == "string" and type(spec) == "table" then
      local expanded = expand(spec, plugin_dir)
      local command = type(expanded.command) == "string" and expanded.command or nil
      local url = type(expanded.url) == "string" and expanded.url or nil
      if command or url then
        table.insert(result, {
          name = name,
          command = command,
          args = string_list(expanded.args),
          env = string_map(expanded.env),
          url = url,
        })
      end
    end
  end
  table.sort(result, function(a, b)
    return a.name < b.name
  end)
  return result
end

--- The skills a plugin bundles, in `skills/<dir>/SKILL.md` order.
---
--- `name` falls back to the directory name because that is what Claude Code does when the
--- frontmatter omits it; `description` falls back to "" rather than dropping the skill, so a
--- skill that is missing one still appears where the user can see it is incomplete.
--- @param plugin_dir string absolute path of the plugin
--- @return Vibing.PluginSkill[]
function M.skills(plugin_dir)
  local files = vim.fn.glob(plugin_dir .. "/skills/*/SKILL.md", false, true)
  table.sort(files)

  local result = {}
  for _, path in ipairs(files) do
    local ok, lines = pcall(vim.fn.readfile, path, "", 60)
    if ok and type(lines) == "table" then
      table.insert(result, {
        name = YamlFrontmatter.read(lines, "name") or vim.fs.basename(vim.fs.dirname(path)),
        description = YamlFrontmatter.read(lines, "description") or "",
        path = path,
      })
    end
  end
  return result
end

return M
