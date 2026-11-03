--- OpenCode plugin generator for vibing.nvim permission gate.
---
--- Writes a throwaway OpenCode plugin to <cwd>/.vibing/opencode-plugin-<instance>/ whose
--- index.js registers vibing's pre-tool-use.sh via ctx.tool.hook("execute.before").
--- OpenCode loads it through OPENCODE_CONFIG_CONTENT's `plugins` array.
--- @module vibing.infrastructure.hooks.opencode_settings_generator

local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local Fs = require("vibing.core.utils.fs")

local M = {}

local PLUGIN_NAME = "vibing-nvim-permissions"

local NAME_PREFIX = "opencode-plugin-"
local NAME_SUFFIX = ""

function M.hook_timeout_sec()
  return require("vibing.infrastructure.hooks.wait_budget").cli_timeout_sec()
end

function M.plugin_dir(cwd)
  local InstanceKey = require("vibing.infrastructure.rpc.instance_key")
  return vim.fn.resolve(cwd) .. "/.vibing/" .. InstanceKey.name(NAME_PREFIX, NAME_SUFFIX)
end

local function build_index_js()
  return table.concat({
    "import { spawnSync } from 'node:child_process';",
    "",
    "export default {",
    "  id: '" .. PLUGIN_NAME .. "',",
    "  async setup(ctx) {",
    "    const script = process.env.VIBING_OPENCODE_HOOK_SCRIPT;",
    "    const timeoutSec = parseInt(process.env.VIBING_OPENCODE_HOOK_TIMEOUT_SEC || '30', 10);",
    "    await ctx.tool.hook('execute.before', async (event) => {",
    "      const payload = {",
    "        hookEventName: 'PreToolUse',",
    "        tool: event.tool,",
    "        input: event.input || {},",
    "        toolCallId: event.id,",
    "        sessionID: event.sessionID,",
    "        cwd: process.cwd(),",
    "      };",
    "      const res = spawnSync(script, [], { input: JSON.stringify(payload), encoding: 'utf8', timeout: timeoutSec * 1000 });",
    "      if (res.error) {",
    "        throw new Error('vibing.nvim permission check failed: ' + res.error.message);",
    "      }",
    "      if (res.status === 2) {",
    "        throw new Error((res.stderr || 'Denied by vibing.nvim').trim());",
    "      }",
    "      if (res.status !== 0) {",
    "        throw new Error('vibing.nvim permission check exited with code ' + res.status);",
    "      }",
    "    });",
    "  },",
    "};",
    "",
  }, "\n")
end

local function sweep_dead_instances(vibing_dir)
  require("vibing.infrastructure.rpc.instance_key").sweep(vibing_dir, NAME_PREFIX, NAME_SUFFIX, function(path)
    vim.fn.delete(path, "rf")
  end)
end

function M.ensure(cwd, dialect)
  local resolved = vim.fn.resolve(cwd or vim.fn.getcwd())
  local dir = M.plugin_dir(resolved)
  Fs.ensure_dir(dir)
  sweep_dead_instances(resolved .. "/.vibing")

  local path = dir .. "/index.js"
  local tmp_path = string.format("%s.%d.tmp", path, vim.loop.getpid())
  local f, err = io.open(tmp_path, "w")
  if not f then
    error("Failed to create OpenCode plugin: " .. tmp_path .. " (" .. tostring(err) .. ")")
  end
  f:write(build_index_js())
  f:close()

  local ok, rename_err = os.rename(tmp_path, path)
  if not ok then
    os.remove(tmp_path)
    error("Failed to install OpenCode plugin: " .. path .. " (" .. tostring(rename_err) .. ")")
  end

  return dir
end

return M
