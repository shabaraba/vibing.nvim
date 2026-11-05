---@diagnostic disable: undefined-field
local Builder = require("vibing.infrastructure.adapter.modules.commandcode_command_builder")
local Fs = require("vibing.core.utils.fs")
local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
local helper = require("tests.helpers.adapter_stream")

--- Every value passed with `--skill`.
--- @param argv string[]
--- @return string[]
local function skill_paths(argv)
  local paths = {}
  for i, token in ipairs(argv) do
    if token == "--skill" and argv[i + 1] then
      table.insert(paths, argv[i + 1])
    end
  end
  return paths
end

describe("commandcode_command_builder", function()
  local original_exepath
  local temp_root

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("commandcode")
    end
    helper.reset_path_caches()
    PluginDirs.clear_cache()
    temp_root = vim.fn.tempname()
    vim.fn.mkdir(temp_root, "p")
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    helper.reset_path_caches()
    PluginDirs.clear_cache()
    vim.fn.delete(temp_root, "rf")
  end)

  --- Create a plugin directory, with a `skills/<name>/SKILL.md` when `with_skills`.
  --- @param name string
  --- @param with_skills boolean
  --- @return string path
  local function write_plugin(name, with_skills)
    local dir = temp_root .. "/" .. name
    Fs.ensure_dir(dir .. "/.claude-plugin")
    vim.fn.writefile({ vim.json.encode({ name = name }) }, dir .. "/.claude-plugin/plugin.json")
    if with_skills then
      Fs.ensure_dir(dir .. "/skills/" .. name)
      vim.fn.writefile({ "---", "name: " .. name, "description: a probe", "---", "", "body" }, dir .. "/skills/" .. name .. "/SKILL.md")
    end
    return dir
  end

  describe("skill_args", function()
    it("hands each plugin's skills directory to --skill", function()
      -- Command Code has no --plugin-dir; --skill is how a plugin's skills travel.
      local args = Builder.skill_args({ opts = {}, config = {} })
      local own = PluginDirs.self_plugin_dir()
      assert.same({ "--skill", own .. "/skills" }, args)
    end)

    it("skips a plugin that bundles no skills", function()
      local without = write_plugin("no-skills", false)
      local with = write_plugin("with-skills", true)
      local args = Builder.skill_args({
        opts = {},
        config = { integrations = { plugins = { self = false, project_dir = false, extra = { without, with } } } },
      })
      assert.same({ "--skill", with .. "/skills" }, args)
    end)

    it("is left off a lightweight call", function()
      local cmd = Builder.build("hi", { lightweight = true }, "sess-1", {}, nil)
      assert.same({}, skill_paths(cmd))
    end)

    it("rides on both transports", function()
      local oneshot = skill_paths(Builder.build("hi", {}, "sess-1", {}, nil))
      local duplex = skill_paths(Builder.build("hi", { _process_model = "duplex" }, "sess-1", {}, nil))
      assert.equals(1, #oneshot)
      assert.same(oneshot, duplex)
    end)

    it("lands ahead of the acp subcommand", function()
      -- `commandcode acp` takes no options of its own; a flag after it is not parsed.
      local cmd = Builder.build("hi", { _process_model = "duplex" }, "sess-1", {}, nil)
      local acp = vim.fn.index(cmd, "acp")
      local skill = vim.fn.index(cmd, "--skill")
      assert.is_true(skill > -1 and skill < acp, "expected --skill before acp in " .. vim.inspect(cmd))
    end)
  end)

end)
