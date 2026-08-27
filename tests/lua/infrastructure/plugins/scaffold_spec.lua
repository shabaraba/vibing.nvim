local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local Scaffold = require("vibing.infrastructure.plugins.scaffold")
local ScaffoldFiles = require("vibing.infrastructure.plugins.scaffold_files")

describe("plugins scaffold", function()
  local project_root
  local original_getcwd

  local function plugins_dir()
    return project_root .. "/.vibing/plugins"
  end

  --- An empty table means "no agent.plugins at all", which disables project_dir. Real callers
  --- always pass a resolved config, so the tests spell the relevant part out.
  --- @param overrides table|nil
  local function config(overrides)
    return {
      agent = {
        plugins = vim.tbl_extend(
          "force",
          { self = false, project_dir = ".vibing/plugins" },
          overrides or {}
        ),
      },
    }
  end

  before_each(function()
    PluginDirs.clear_cache()
    project_root = vim.fn.tempname()
    vim.fn.mkdir(project_root, "p")
    original_getcwd = vim.fn.getcwd
    vim.fn.getcwd = function()
      return project_root
    end
  end)

  after_each(function()
    vim.fn.getcwd = original_getcwd
    vim.fn.delete(project_root, "rf")
    PluginDirs.clear_cache()
  end)

  describe("ensure", function()
    it("seeds the plugins directory with the template plugin", function()
      assert.is_true(Scaffold.ensure(project_root, config()))

      assert.equals(
        1,
        vim.fn.filereadable(
          plugins_dir() .. "/" .. ScaffoldFiles.TEMPLATE_DIR .. "/.claude-plugin/plugin.json"
        )
      )
    end)

    it("leaves the template inactive so it costs no context", function()
      Scaffold.ensure(project_root, config())

      -- The underscore prefix is what keeps it out of the glob; if the name ever loses it,
      -- every project would start shipping the example skill's description on every request
      -- and listing it in the `/` picker.
      assert.same({}, PluginDirs.resolve(project_root, config()))
    end)

    it("does not run again once the directory exists", function()
      Scaffold.ensure(project_root, config())
      local template = plugins_dir() .. "/" .. ScaffoldFiles.TEMPLATE_DIR
      vim.fn.delete(template, "rf")

      assert.is_false(Scaffold.ensure(project_root, config()))
      assert.equals(0, vim.fn.isdirectory(template))
    end)

    it("does nothing when project_dir is disabled", function()
      assert.is_false(Scaffold.ensure(project_root, config({ project_dir = false })))
      assert.equals(0, vim.fn.isdirectory(plugins_dir()))
    end)
  end)

  describe("create", function()
    it("writes a plugin that --plugin-dir actually loads", function()
      local path, problem = Scaffold.create("my-plugin", project_root, config())

      assert.is_nil(problem)
      assert.equals(plugins_dir() .. "/my-plugin", path)
      assert.same({ plugins_dir() .. "/my-plugin" }, PluginDirs.resolve(project_root, config()))
    end)

    it("names the plugin in its manifest after the directory", function()
      Scaffold.create("my-plugin", project_root, config())

      local entries = PluginDirs.resolve_entries(project_root, config())
      assert.equals("my-plugin", entries[1].name)
    end)

    it("ships a skill and an agent", function()
      local path = Scaffold.create("my-plugin", project_root, config())

      assert.equals(1, vim.fn.filereadable(path .. "/skills/example/SKILL.md"))
      assert.equals(1, vim.fn.filereadable(path .. "/agents/example-agent.md"))
    end)

    it("seeds the template too, for a first run that skipped the chat", function()
      Scaffold.create("my-plugin", project_root, config())

      assert.equals(
        1,
        vim.fn.isdirectory(plugins_dir() .. "/" .. ScaffoldFiles.TEMPLATE_DIR)
      )
    end)

    it("refuses to overwrite an existing plugin", function()
      Scaffold.create("my-plugin", project_root, config())
      local path, problem = Scaffold.create("my-plugin", project_root, config())

      assert.is_nil(path)
      assert.is_truthy(problem:match("already exists"))
    end)

    it("rejects names that would break skill namespacing or the shell", function()
      for _, name in ipairs({ "", "My Plugin", "../escape", "plugin:name" }) do
        local path, problem = Scaffold.create(name, project_root, config())
        assert.is_nil(path, name)
        assert.is_truthy(problem)
      end
    end)
  end)
end)
