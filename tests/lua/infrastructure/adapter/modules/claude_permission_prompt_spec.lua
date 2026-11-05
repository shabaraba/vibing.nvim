---@diagnostic disable: undefined-field
--- `--permission-prompt-tool` is passed only when the tool it names will exist this turn.
---
--- A name that does not resolve fails the whole turn (exit 1) the first time claude's gate consults
--- it, so every case below where the flag is omitted is one where passing it would have turned a
--- refused edit into a dead turn.
local CliCommandBuilder = require("vibing.infrastructure.adapter.modules.cli_command_builder")
local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local Claude = require("vibing.infrastructure.adapter.backends.claude")

describe("claude permission prompt tool", function()
  local plugin_dir, original_self, original_resolve, original_exepath, original_native

  local PLUGIN_NAME = "mcp__plugin_vibing-nvim_vibing-nvim__nvim_permission_prompt"
  local BARE_NAME = "mcp__vibing-nvim__nvim_permission_prompt"

  local function value_of(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return cmd[i + 1]
      end
    end
    return nil
  end

  local function count(cmd, flag)
    local n = 0
    for _, arg in ipairs(cmd) do
      if arg == flag then
        n = n + 1
      end
    end
    return n
  end

  local function build(opts, config)
    return CliCommandBuilder.build("hello", opts or {}, nil, config or {}, nil)
  end

  before_each(function()
    plugin_dir = vim.fn.tempname()
    vim.fn.mkdir(plugin_dir .. "/mcp-server/dist/handlers", "p")
    vim.fn.writefile({ "" }, plugin_dir .. "/mcp-server/dist/index.js")
    vim.fn.writefile({ "" }, plugin_dir .. "/mcp-server/dist/handlers/permission.js")

    original_self, original_resolve = PluginDirs.self_plugin_dir, PluginDirs.resolve
    PluginDirs.self_plugin_dir = function()
      return plugin_dir
    end
    PluginDirs.resolve = function()
      return { plugin_dir }
    end

    original_exepath = vim.fn.exepath
    vim.fn.exepath = function(name)
      return name == "claude" and "/usr/local/bin/claude" or original_exepath(name)
    end
    CliCommandBuilder._reset_path_cache()

    original_native = Claude.native_approval
    Claude.native_approval = { measured_wait_floor_sec = 100000 }
  end)

  after_each(function()
    PluginDirs.self_plugin_dir, PluginDirs.resolve = original_self, original_resolve
    vim.fn.exepath = original_exepath
    CliCommandBuilder._reset_path_cache()
    Claude.native_approval = original_native
    vim.fn.delete(plugin_dir, "rf")
  end)

  it("names the plugin-form tool and hides it from the model", function()
    local cmd = build()
    assert.equals(PLUGIN_NAME, value_of(cmd, "--permission-prompt-tool"))
    assert.equals(PLUGIN_NAME, value_of(cmd, "--disallowedTools"))
  end)

  it("names the bare tool when the server is re-registered by hand", function()
    local cmd = build({}, { ai = { agents = { claude = { mcp = { inherit_cli_servers = false } } } } })
    assert.equals(BARE_NAME, value_of(cmd, "--permission-prompt-tool"))
    assert.equals(BARE_NAME, value_of(cmd, "--disallowedTools"))
  end)

  it("joins the user's own deny list rather than adding a second flag", function()
    local cmd = build({ permissions_deny = { "WebFetch" } })
    assert.equals(1, count(cmd, "--disallowedTools"))
    assert.equals("WebFetch," .. PLUGIN_NAME, value_of(cmd, "--disallowedTools"))
  end)

  it("is omitted when the backend has no measurement covering the wait", function()
    Claude.native_approval = nil
    local cmd = build({ permissions_deny = { "WebFetch" } })
    assert.is_nil(value_of(cmd, "--permission-prompt-tool"))
    assert.equals("WebFetch", value_of(cmd, "--disallowedTools"))
  end)

  it("is omitted when the configured wait exceeds the measurement", function()
    Claude.native_approval = { measured_wait_floor_sec = 960 }
    local config = require("vibing.config")
    local original_get = config.get
    config.get = function()
      return { permissions = { approval_wait_sec = 1200 } }
    end
    local ok, cmd = pcall(build)
    config.get = original_get
    assert.is_true(ok, cmd)
    assert.is_nil(value_of(cmd, "--permission-prompt-tool"))
  end)

  it("is omitted when the server has not been built yet", function()
    vim.fn.delete(plugin_dir .. "/mcp-server/dist/index.js")
    assert.is_nil(value_of(build(), "--permission-prompt-tool"))
  end)

  it("is omitted when the build predates the tool", function()
    vim.fn.delete(plugin_dir .. "/mcp-server/dist/handlers/permission.js")
    assert.is_nil(value_of(build(), "--permission-prompt-tool"))
  end)

  it("is omitted when vibing's own plugin is not loaded this turn", function()
    PluginDirs.resolve = function()
      return {}
    end
    assert.is_nil(value_of(build(), "--permission-prompt-tool"))
  end)

  it("reads back off the built argv what the process entry records", function()
    assert.equals(PLUGIN_NAME, Claude.permission_prompt_tool(build()))
    Claude.native_approval = nil
    assert.is_nil(Claude.permission_prompt_tool(build()))
  end)

  it("is never on the lightweight path", function()
    local cmd = build({ lightweight = true })
    assert.is_nil(value_of(cmd, "--permission-prompt-tool"))
    assert.is_nil(value_of(cmd, "--disallowedTools"))
  end)
end)
