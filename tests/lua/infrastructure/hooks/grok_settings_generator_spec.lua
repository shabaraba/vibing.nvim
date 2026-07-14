local GrokSettingsGenerator = require("vibing.infrastructure.hooks.grok_settings_generator")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

describe("grok_settings_generator", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    if tmp_dir then
      vim.fn.delete(tmp_dir, "rf")
    end
  end)

  it("writes a PreToolUse hook JSON under <cwd>/.grok/hooks/", function()
    local path = GrokSettingsGenerator.ensure(tmp_dir)
    assert.is_true(vim.fn.filereadable(path) == 1)

    local f = io.open(path, "r")
    assert.is_not_nil(f)
    local content = f:read("*a")
    f:close()

    local ok, decoded = pcall(vim.json.decode, content)
    assert.is_true(ok)
    assert.is_table(decoded.hooks)
    assert.is_table(decoded.hooks.PreToolUse)

    local entry = decoded.hooks.PreToolUse[1]
    assert.equals(".*", entry.matcher)
    assert.equals("command", entry.hooks[1].type)
    assert.equals(SettingsGenerator.get_hook_script_path(), entry.hooks[1].command)
    assert.equals(120, entry.hooks[1].timeout)
  end)

  it("rewrites the hook file on subsequent ensure calls (path may change on plugin update)", function()
    local path1 = GrokSettingsGenerator.ensure(tmp_dir)
    local path2 = GrokSettingsGenerator.ensure(tmp_dir)
    assert.equals(path1, path2)
    assert.is_true(vim.fn.filereadable(path2) == 1)
  end)

  it("returns hook_file_path for a cwd without writing", function()
    local expected = tmp_dir .. "/.grok/hooks/vibing-nvim-pre-tool-use.json"
    assert.equals(expected, GrokSettingsGenerator.hook_file_path(tmp_dir))
  end)
end)
