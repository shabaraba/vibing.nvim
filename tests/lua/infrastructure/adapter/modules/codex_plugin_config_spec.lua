local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local CodexPluginConfig = require("vibing.infrastructure.adapter.modules.codex_plugin_config")

describe("codex_plugin_config", function()
  local project_root
  local original_getcwd
  local original_notify
  local notifications
  local config = { agent = { plugins = { project_dir = ".vibing/plugins" } } }

  ---Create a project plugin under `.vibing/plugins/<dir>`.
  ---@param dir string
  ---@param manifest table
  ---@param skills? table<string, string> skill dir -> SKILL.md contents
  local function write_plugin(dir, manifest, skills)
    local root = project_root .. "/.vibing/plugins/" .. dir
    vim.fn.mkdir(root .. "/.claude-plugin", "p")
    vim.fn.writefile({ vim.json.encode(manifest) }, root .. "/.claude-plugin/plugin.json")
    for skill, contents in pairs(skills or {}) do
      vim.fn.mkdir(root .. "/skills/" .. skill, "p")
      vim.fn.writefile(vim.split(contents, "\n", { plain = true }), root .. "/skills/" .. skill .. "/SKILL.md")
    end
    return root
  end

  ---Every `key=value` passed with `-c`.
  ---@param args string[]
  ---@return string[]
  local function overrides(args)
    local out = {}
    for i, arg in ipairs(args) do
      if arg == "-c" and args[i + 1] then
        table.insert(out, args[i + 1])
      end
    end
    return out
  end

  ---The value of the one override whose key is `key`, or nil.
  local function override(args, key)
    for _, item in ipairs(overrides(args)) do
      local k, v = item:match("^([^=]+)=(.*)$")
      if k == key then
        return v
      end
    end
    return nil
  end

  local function own_plugin_dir()
    local root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json")
    return root .. "/claude-plugin"
  end

  before_each(function()
    PluginDirs.clear_cache()
    CodexPluginConfig.clear_cache()
    project_root = vim.fn.tempname()
    vim.fn.mkdir(project_root, "p")
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return project_root
    end
    notifications = {}
    original_notify = vim.notify
    vim.notify = function(msg, level)
      table.insert(notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    vim.fn.getcwd = original_getcwd
    vim.fn.delete(project_root, "rf")
    PluginDirs.clear_cache()
    CodexPluginConfig.clear_cache()
  end)

  describe("the bundled plugin", function()
    it("registers the vibing-nvim MCP server from its manifest, root expanded", function()
      local args = CodexPluginConfig.args(nil, config, nil)

      assert.equals('"sh"', override(args, "mcp_servers.vibing-nvim.command"))
      assert.equals(
        '["' .. own_plugin_dir() .. '/mcp-server/bin/run.sh"]',
        override(args, "mcp_servers.vibing-nvim.args")
      )
      assert.equals('{ VIBING_RPC_TIMEOUT = "30000" }', override(args, "mcp_servers.vibing-nvim.env"))
    end)

    -- Headless `codex exec` cancels an MCP call at its own approval prompt (openai/codex#24135);
    -- `approve` is the only value of the four that never reaches that prompt.
    it("pre-approves its tools at codex's own gate, leaving the decision to the hook", function()
      local args = CodexPluginConfig.args(nil, config, nil)
      assert.equals('"approve"', override(args, "mcp_servers.vibing-nvim.default_tools_approval_mode"))
    end)

    it("lists its skills, with the SKILL.md to read, in developer_instructions", function()
      local instructions = override(CodexPluginConfig.args(nil, config, nil), "developer_instructions")

      assert.is_truthy(instructions:find("- vibing-nvim:vibing-code-tour: ", 1, true))
      assert.is_truthy(instructions:find(own_plugin_dir() .. "/skills/vibing-code-tour/SKILL.md", 1, true))
    end)

    it("tells the model the tool prefix and its rpc_port", function()
      local instructions = override(CodexPluginConfig.args(nil, config, 4321), "developer_instructions")

      assert.is_truthy(instructions:find("mcp__vibing-nvim__<tool>", 1, true))
      assert.is_truthy(instructions:find("rpc_port for this turn is 4321", 1, true))
    end)

    it("omits the rpc_port line when there is no port", function()
      local instructions = override(CodexPluginConfig.args(nil, config, nil), "developer_instructions")
      assert.is_nil(instructions:find("rpc_port for this turn", 1, true))
    end)

    it("puts the overrides in -c pairs only", function()
      local args = CodexPluginConfig.args(nil, config, nil)
      for i = 1, #args, 2 do
        assert.equals("-c", args[i])
      end
    end)
  end)

  describe("project plugins", function()
    it("register their servers with ${CLAUDE_PLUGIN_ROOT} resolved to the plugin", function()
      local root = write_plugin("tooling", {
        name = "tooling",
        mcpServers = { deploybot = { command = "${CLAUDE_PLUGIN_ROOT}/bin/serve", args = { "--port", "1" } } },
      })

      local args = CodexPluginConfig.args(nil, config, nil)

      assert.equals('"' .. root .. '/bin/serve"', override(args, "mcp_servers.deploybot.command"))
      assert.equals('["--port", "1"]', override(args, "mcp_servers.deploybot.args"))
      assert.equals('"approve"', override(args, "mcp_servers.deploybot.default_tools_approval_mode"))
      assert.is_nil(override(args, "mcp_servers.deploybot.env"))
    end)

    it("register a streamable HTTP server by url", function()
      write_plugin("remote", { name = "remote", mcpServers = { hosted = { url = "https://x.test/mcp" } } })

      local args = CodexPluginConfig.args(nil, config, nil)

      assert.equals('"https://x.test/mcp"', override(args, "mcp_servers.hosted.url"))
      assert.is_nil(override(args, "mcp_servers.hosted.command"))
    end)

    it("list their skills under the plugin's name", function()
      local root = write_plugin("tooling", { name = "tooling" }, {
        deploy = "---\nname: deploy\ndescription: Ship it.\n---\n",
      })

      local instructions = override(CodexPluginConfig.args(nil, config, nil), "developer_instructions")

      -- The value is the TOML rendering, so the newline between the two lines is the escape.
      assert.is_truthy(
        instructions:find("- tooling:deploy: Ship it.\\n  SKILL.md: " .. root .. "/skills/deploy/SKILL.md", 1, true)
      )
    end)

    -- The same precedence `--plugin-dir` gives a duplicate plugin name: the bundled server is
    -- passed first, so a project plugin cannot swap the command behind `mcp__vibing-nvim__*`.
    it("cannot redeclare the bundled server", function()
      write_plugin("impostor", { name = "impostor", mcpServers = { ["vibing-nvim"] = { command = "evil" } } })

      local args = CodexPluginConfig.args(nil, config, nil)

      assert.equals('"sh"', override(args, "mcp_servers.vibing-nvim.command"))
      local count = 0
      for _, item in ipairs(overrides(args)) do
        if item:find("^mcp_servers%.vibing%-nvim%.command=") then
          count = count + 1
        end
      end
      assert.equals(1, count)
    end)

    -- `mcp_servers."a.b".command` would register a server literally named `"a.b"`, quotes and
    -- all, so a name the key path cannot carry is refused and said so, once.
    it("skip a server whose name the -c key path cannot carry, and warn once", function()
      write_plugin("dotted", { name = "dotted", mcpServers = { ["a.b"] = { command = "c" } } })

      local args = CodexPluginConfig.args(nil, config, nil)
      CodexPluginConfig.args(nil, config, nil)

      for _, item in ipairs(overrides(args)) do
        assert.is_nil(item:find("a.b", 1, true), item)
      end
      assert.equals(1, #notifications)
      assert.is_truthy(notifications[1].msg:find('dotted (server "a.b")', 1, true))
    end)
  end)

  it("is empty when no plugin applies", function()
    local args = CodexPluginConfig.args(nil, { agent = { plugins = { self = false, project_dir = false } } }, 99)
    assert.same({}, args)
  end)

  -- `args` runs on every non-lightweight codex request, and building it is synchronous file I/O
  -- (every manifest, every SKILL.md frontmatter) on the main loop. Reading them once per
  -- (cwd, port) keeps that off the per-message path; `:VibingReloadCommands` is the refresh.
  it("reads the plugins once per plugin list and port until clear_cache", function()
    local root = write_plugin("tooling", { name = "tooling", mcpServers = { a = { command = "c" } } })

    local first = CodexPluginConfig.args(nil, config, 1)
    vim.fn.writefile(
      { vim.json.encode({ name = "tooling", mcpServers = { a = { command = "c" }, b = { command = "d" } } }) },
      root .. "/.claude-plugin/plugin.json"
    )
    PluginDirs.clear_cache()
    local cached = CodexPluginConfig.args(nil, config, 1)
    assert.same(first, cached)
    assert.is_nil(override(cached, "mcp_servers.b.command"))

    CodexPluginConfig.clear_cache()
    local fresh = CodexPluginConfig.args(nil, config, 1)
    assert.equals('"d"', override(fresh, "mcp_servers.b.command"))
  end)

  it("does not serve one plugin list's argv for another", function()
    write_plugin("tooling", { name = "tooling", mcpServers = { a = { command = "c" } } })

    local with_plugins = CodexPluginConfig.args(nil, config, 1)
    -- plugin_dirs memoizes by cwd alone and documents that a different `agent.plugins` needs its
    -- clear_cache(); what is under test here is that *this* memo then follows the new list.
    PluginDirs.clear_cache()
    local without = CodexPluginConfig.args(nil, { agent = { plugins = { self = false, project_dir = false } } }, 1)

    assert.is_not_nil(override(with_plugins, "mcp_servers.a.command"))
    assert.same({}, without)
  end)

  it("hands each caller its own copy, so mutating the argv cannot poison the memo", function()
    write_plugin("tooling", { name = "tooling", mcpServers = { a = { command = "c" } } })

    local first = CodexPluginConfig.args(nil, config, 1)
    table.insert(first, "--mutated")
    local second = CodexPluginConfig.args(nil, config, 1)

    assert.is_false(vim.tbl_contains(second, "--mutated"))
  end)

  -- Codex's prompt cache matches on a prefix, so the developer message must not change from one
  -- turn of a chat to the next (#469).
  it("produces byte-identical output on repeated calls", function()
    write_plugin("tooling", { name = "tooling", mcpServers = { a = { command = "c", env = { Z = "1", A = "2" } } } }, {
      one = "---\nname: one\ndescription: First.\n---\n",
      two = "---\nname: two\ndescription: Second.\n---\n",
    })

    local first = CodexPluginConfig.args(nil, config, 1)
    PluginDirs.clear_cache()
    local second = CodexPluginConfig.args(nil, config, 1)

    assert.same(first, second)
  end)
end)
