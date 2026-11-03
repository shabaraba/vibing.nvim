--- Inline config for the OpenCode CLI, injected through OPENCODE_CONFIG_CONTENT.
--- @module vibing.infrastructure.adapter.modules.opencode_config

local Notify = require("vibing.core.utils.notify")
local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")
local WaitBudget = require("vibing.infrastructure.hooks.wait_budget")

local M = {}

local function expand_root(value, root)
  if type(value) ~= "string" then
    return value
  end
  return (value:gsub("%${CLAUDE_PLUGIN_ROOT}", root))
end

local function convert_server(server, plugin_dir, env)
  if server.url then
    return { type = "remote", url = server.url, codemode = false }
  end
  local command = server.command
  local args = {}
  for _, a in ipairs(server.args or {}) do
    table.insert(args, expand_root(a, plugin_dir))
  end
  local environment = {}
  for k, v in pairs(server.env or {}) do
    environment[k] = tostring(v)
  end
  local port = require("vibing.infrastructure.rpc.server").get_port()
  if port then
    environment.VIBING_NVIM_RPC_PORT = tostring(port)
    environment.VIBING_NVIM_CONTEXT = "true"
  end
  return {
    type = "local",
    command = vim.list_extend({ command }, args),
    environment = environment,
    codemode = false,
  }
end

--- @param env table<string, string>
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
function M.apply(env, opts, config)
  opts = opts or {}
  config = config or {}
  local lightweight = opts.lightweight == true
  local plugin_dir = opts._opencode_plugin_dir

  if lightweight then
    env.OPENCODE_DISABLE_PROJECT_CONFIG = "1"
    local cfg = { permissions = { { action = "*", resource = "*", effect = "deny" } } }
    env.OPENCODE_CONFIG_CONTENT = vim.json.encode(cfg)
    return
  end

  -- Hook env vars for the plugin JS.
  SettingsGenerator.get_hook_script_path()
  env.VIBING_OPENCODE_HOOK_SCRIPT = SettingsGenerator.get_hook_script_path()
  env.VIBING_OPENCODE_HOOK_TIMEOUT_SEC = tostring(WaitBudget.cli_timeout_sec())

  local is_bypass = (opts.permission_mode or "default") == "bypassPermissions"

  -- Missing plugin handling.
  if not plugin_dir then
    if is_bypass then
      Notify.warn_once(
        "opencode_bridge_missing_bypass",
        "OpenCode is running without vibing.nvim's permission bridge, so this turn produces no "
          .. "### Modified Files and no `gd` diff."
      )
    else
      Notify.warn_once(
        "opencode_bridge_missing",
        "OpenCode is running without vibing.nvim's permission bridge, so it has been restricted to "
          .. "read-only tools. Run ./build.sh to build the plugin."
      )
    end
  end

  -- Build base config from existing inline content.
  local cfg = {}
  local raw = env.OPENCODE_CONFIG_CONTENT
  if type(raw) == "string" and raw ~= "" then
    local ok, decoded = pcall(vim.json.decode, raw)
    if ok and type(decoded) == "table" then
      cfg = decoded
    end
  end
  cfg.plugins = cfg.plugins or {}
  cfg.mcp = cfg.mcp or {}
  cfg.mcp.servers = cfg.mcp.servers or {}
  cfg.permissions = cfg.permissions or {}

  if plugin_dir and not vim.tbl_contains(cfg.plugins, plugin_dir) then
    table.insert(cfg.plugins, plugin_dir)
  end

  -- MCP servers from plugin dirs (non-lightweight).
  local seen = {}
  local self_dir = PluginDirs.self_plugin_dir and PluginDirs.self_plugin_dir() or nil
  for _, entry in ipairs(PluginDirs.resolve_entries(opts.cwd, config)) do
    for _, server in ipairs(PluginContents.mcp_servers(entry.path)) do
      if not seen[server.name] then
        seen[server.name] = true
        cfg.mcp.servers[server.name] = convert_server(server, entry.path, env)
      end
    end
  end

  -- Permission rules.
  if not plugin_dir and not is_bypass then
    local deny_rules = {
      { action = "edit", resource = "*", effect = "deny" },
      { action = "shell", resource = "*", effect = "deny" },
      { action = "subagent", resource = "*", effect = "deny" },
      { action = "webfetch", resource = "*", effect = "deny" },
      { action = "websearch", resource = "*", effect = "deny" },
      { action = "execute", resource = "*", effect = "deny" },
      { action = "experimental_image_generate", resource = "*", effect = "deny" },
      { action = "*_*", resource = "*", effect = "deny" },
    }
    for _, r in ipairs(deny_rules) do
      table.insert(cfg.permissions, r)
    end
  elseif plugin_dir then
    -- Deny Code Mode's execute tool.
    table.insert(cfg.permissions, { action = "execute", resource = "*", effect = "deny" })
  end

  env.OPENCODE_CONFIG_CONTENT = vim.json.encode(cfg)
end

return M
