local PluginContents = require("vibing.infrastructure.plugins.plugin_contents")

describe("plugin_contents", function()
  local plugin_dir

  ---@param files table<string, string> relative path -> contents
  local function write_plugin(files)
    for rel, contents in pairs(files) do
      local path = plugin_dir .. "/" .. rel
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile(vim.split(contents, "\n", { plain = true }), path)
    end
  end

  ---The repo's own claude-plugin/.
  local function own_plugin_dir()
    local root = vim.fs.root(debug.getinfo(1, "S").source:sub(2), "package.json")
    return root .. "/claude-plugin"
  end

  before_each(function()
    plugin_dir = vim.fn.tempname()
    vim.fn.mkdir(plugin_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(plugin_dir, "rf")
  end)

  describe("mcp_servers", function()
    it("expands ${CLAUDE_PLUGIN_ROOT} in command, args and env alike", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({
          name = "p",
          mcpServers = {
            srv = {
              command = "${CLAUDE_PLUGIN_ROOT}/bin/node",
              args = { "${CLAUDE_PLUGIN_ROOT}/server.js", "--flag" },
              env = { ROOT = "${CLAUDE_PLUGIN_ROOT}", PLAIN = "x" },
            },
          },
        }),
      })

      local servers = PluginContents.mcp_servers(plugin_dir)

      assert.equals(1, #servers)
      assert.equals("srv", servers[1].name)
      assert.equals(plugin_dir .. "/bin/node", servers[1].command)
      assert.same({ plugin_dir .. "/server.js", "--flag" }, servers[1].args)
      assert.same({ ROOT = plugin_dir, PLAIN = "x" }, servers[1].env)
      assert.is_nil(servers[1].url)
    end)

    it("returns servers sorted by name", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({
          name = "p",
          mcpServers = { zeta = { command = "z" }, alpha = { command = "a" } },
        }),
      })

      local names = vim.tbl_map(function(s)
        return s.name
      end, PluginContents.mcp_servers(plugin_dir))

      assert.same({ "alpha", "zeta" }, names)
    end)

    it("keeps a streamable HTTP server by its url", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({
          name = "p",
          mcpServers = { remote = { url = "https://example.test/mcp" } },
        }),
      })

      local servers = PluginContents.mcp_servers(plugin_dir)

      assert.equals("https://example.test/mcp", servers[1].url)
      assert.is_nil(servers[1].command)
    end)

    it("drops a server with neither command nor url", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({
          name = "p",
          mcpServers = { broken = { args = { "x" } }, ok = { command = "c" } },
        }),
      })

      local servers = PluginContents.mcp_servers(plugin_dir)

      assert.equals(1, #servers)
      assert.equals("ok", servers[1].name)
    end)

    it("ignores non-string args and env values rather than passing them on", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({
          name = "p",
          mcpServers = { srv = { command = "c", args = { "a", 1 }, env = { N = 1, S = "s" } } },
        }),
      })

      local servers = PluginContents.mcp_servers(plugin_dir)

      assert.same({ "a" }, servers[1].args)
      assert.same({ S = "s" }, servers[1].env)
    end)

    -- Claude Code's `"mcpServers": "./.mcp.json"` form, resolved against the plugin root.
    it("follows a string mcpServers to a .mcp.json with the usual wrapper", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({ name = "p", mcpServers = "./.mcp.json" }),
        [".mcp.json"] = vim.json.encode({
          mcpServers = { srv = { command = "${CLAUDE_PLUGIN_ROOT}/run.sh" } },
        }),
      })

      local servers = PluginContents.mcp_servers(plugin_dir)

      assert.equals("srv", servers[1].name)
      assert.equals(plugin_dir .. "/run.sh", servers[1].command)
    end)

    it("accepts a bare map in that file as well", function()
      write_plugin({
        [".claude-plugin/plugin.json"] = vim.json.encode({ name = "p", mcpServers = "servers.json" }),
        ["servers.json"] = vim.json.encode({ srv = { command = "c" } }),
      })

      assert.equals("srv", PluginContents.mcp_servers(plugin_dir)[1].name)
    end)

    it("returns nothing for a missing, malformed or server-less manifest", function()
      assert.same({}, PluginContents.mcp_servers(plugin_dir))

      write_plugin({ [".claude-plugin/plugin.json"] = "{not json" })
      assert.same({}, PluginContents.mcp_servers(plugin_dir))

      write_plugin({ [".claude-plugin/plugin.json"] = vim.json.encode({ name = "p" }) })
      assert.same({}, PluginContents.mcp_servers(plugin_dir))

      write_plugin({ [".claude-plugin/plugin.json"] = vim.json.encode({ name = "p", mcpServers = "missing.json" }) })
      assert.same({}, PluginContents.mcp_servers(plugin_dir))
    end)

    it("reads the bundled plugin's own server with its root expanded", function()
      local servers = PluginContents.mcp_servers(own_plugin_dir())

      assert.equals(1, #servers)
      assert.equals("vibing-nvim", servers[1].name)
      assert.equals("sh", servers[1].command)
      assert.equals(own_plugin_dir() .. "/mcp-server/bin/run.sh", servers[1].args[1])
      assert.is_nil(servers[1].args[1]:find("${CLAUDE_PLUGIN_ROOT}", 1, true))
    end)
  end)

  describe("skills", function()
    it("reads name and description from each SKILL.md's frontmatter", function()
      write_plugin({
        ["skills/deploy/SKILL.md"] = "---\nname: deploy-it\ndescription: Ship the thing.\n---\n# Deploy\n",
        ["skills/review/SKILL.md"] = "---\nname: review\ndescription: >-\n  Review\n  changes.\n---\n",
      })

      local skills = PluginContents.skills(plugin_dir)

      assert.equals(2, #skills)
      assert.equals("deploy-it", skills[1].name)
      assert.equals("Ship the thing.", skills[1].description)
      assert.equals(plugin_dir .. "/skills/deploy/SKILL.md", skills[1].path)
      assert.equals("review", skills[2].name)
      assert.equals("Review changes.", skills[2].description)
    end)

    it("falls back to the directory name and an empty description", function()
      write_plugin({ ["skills/bare/SKILL.md"] = "# No frontmatter\n" })

      local skills = PluginContents.skills(plugin_dir)

      assert.equals("bare", skills[1].name)
      assert.equals("", skills[1].description)
    end)

    it("ignores files that are not skills/<dir>/SKILL.md", function()
      write_plugin({
        ["skills/README.md"] = "x",
        ["skills/nested/deeper/SKILL.md"] = "---\nname: deep\n---\n",
      })

      assert.same({}, PluginContents.skills(plugin_dir))
    end)

    it("returns nothing for a plugin without a skills directory", function()
      assert.same({}, PluginContents.skills(plugin_dir))
    end)

    it("lists the bundled plugin's skills with absolute paths", function()
      local names = {}
      for _, skill in ipairs(PluginContents.skills(own_plugin_dir())) do
        names[skill.name] = skill.path
      end

      assert.equals(own_plugin_dir() .. "/skills/vibing-code-tour/SKILL.md", names["vibing-code-tour"])
      assert.is_truthy(names["nvim-context"])
    end)
  end)
end)
