--- Create project-local Claude Code plugins under `.vibing/plugins/`.
---
--- The directory is seeded the first time a chat runs in a project, so the convention is
--- discoverable without reading the docs, and `:VibingCreatePlugin` writes further ones on
--- demand. What gets loaded is decided by `plugin_dirs`; this module only puts files on disk.
--- @module vibing.infrastructure.plugins.scaffold

local Config = require("vibing.config")
local Fs = require("vibing.core.utils.fs")
local Files = require("vibing.infrastructure.plugins.scaffold_files")

local M = {}

--- Claude Code namespaces skills as `<plugin>:<skill>` and vibing.nvim passes the directory
--- straight to a shell-invoked CLI, so a name is restricted to what is safe in both.
local NAME_PATTERN = "^[a-z0-9][a-z0-9%-_]*$"

--- Where plugins live for this project. `agent.plugins.project_dir` is the single definition of
--- the convention, so an unset config falls back to the resolved options rather than to a second
--- copy of the default string.
--- @param root string project root
--- @param config Vibing.Config|nil
--- @return string|nil absolute path to the plugins directory, nil when disabled
local function plugins_dir(root, config)
  local resolved = config or Config.get()
  local plugins = (resolved.agent and resolved.agent.plugins) or {}
  local rel = plugins.project_dir
  if type(rel) ~= "string" or rel == "" then
    return nil
  end
  return root .. "/" .. rel
end

--- @param dir string
--- @param files table<string, string>
local function write_files(dir, files)
  for rel, contents in pairs(files) do
    local path = dir .. "/" .. rel
    Fs.ensure_dir(vim.fn.fnamemodify(path, ":h"))

    local handle, err = io.open(path, "w")
    if not handle then
      error(string.format("could not write %s: %s", path, tostring(err)))
    end
    handle:write(contents)
    handle:close()
  end
end

--- @param name string
--- @return boolean ok, string|nil problem
function M.validate_name(name)
  if type(name) ~= "string" or name == "" then
    return false, "plugin name is required"
  end
  if not name:match(NAME_PATTERN) then
    return false, string.format("%q must be lowercase letters, digits, '-' and '_'", name)
  end
  return true, nil
end

--- Seed `.vibing/plugins/` with the template plugin.
---
--- Called on the first request of a session per project. Only a missing plugins directory
--- triggers this, so a user who deleted the template does not get it back on every chat.
--- @param root string|nil project root; defaults to Neovim's cwd
--- @param config Vibing.Config|nil
--- @return boolean seeded whether anything was written
function M.ensure(root, config)
  root = (root and root ~= "") and root or vim.fn.getcwd()
  local base = plugins_dir(root, config)
  if not base or vim.fn.isdirectory(base) == 1 then
    return false
  end

  Fs.ensure_dir(base)
  write_files(base .. "/" .. Files.TEMPLATE_DIR, Files.plugin("example"))
  return true
end

--- Write a new plugin directory.
---
--- Refuses to touch an existing directory: the point of the command is a starting skeleton, and
--- overwriting a plugin someone has been editing is not recoverable from here.
--- @param name string plugin name
--- @param root string|nil project root; defaults to Neovim's cwd
--- @param config Vibing.Config|nil
--- @return string|nil path, string|nil problem
function M.create(name, root, config)
  local ok, problem = M.validate_name(name)
  if not ok then
    return nil, problem
  end

  root = (root and root ~= "") and root or vim.fn.getcwd()
  local base = plugins_dir(root, config)
  if not base then
    return nil, "agent.plugins.project_dir is disabled"
  end

  local dir = base .. "/" .. name
  if vim.fn.isdirectory(dir) == 1 then
    return nil, string.format("%s already exists", dir)
  end

  -- A user who runs the command before ever sending a message would otherwise get a plugin
  -- directory with no template next to it.
  pcall(M.ensure, root, config)

  local written, write_err = pcall(write_files, dir, Files.plugin(name))
  if not written then
    return nil, tostring(write_err)
  end

  return dir, nil
end

return M
