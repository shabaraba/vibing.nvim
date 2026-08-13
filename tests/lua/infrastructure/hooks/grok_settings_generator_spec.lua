local GrokSettingsGenerator = require("vibing.infrastructure.hooks.grok_settings_generator")
local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

describe("grok_settings_generator", function()
  local tmp_dir
  local grok_home
  local saved_grok_home

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")

    -- ensure() records folder trust, which without this lands in the developer's real
    -- ~/.grok/trusted_folders.toml -- trust that cascades to subdirectories and is never expired,
    -- for a tempname() path this spec is about to delete.
    saved_grok_home = vim.env.GROK_HOME
    grok_home = vim.fn.tempname()
    vim.fn.mkdir(grok_home, "p")
    vim.env.GROK_HOME = grok_home
  end)

  after_each(function()
    if tmp_dir then
      vim.fn.delete(tmp_dir, "rf")
    end
    if grok_home then
      vim.fn.delete(grok_home, "rf")
    end
    vim.env.GROK_HOME = saved_grok_home
  end)

  it("records folder trust under $GROK_HOME, never the real ~/.grok", function()
    GrokSettingsGenerator.ensure(tmp_dir)

    local trust_path = grok_home .. "/trusted_folders.toml"
    assert.is_true(vim.fn.filereadable(trust_path) == 1, "trust file must be written under GROK_HOME")

    local f = io.open(trust_path, "r")
    local content = f:read("*a")
    f:close()
    assert.is_truthy(content:find(vim.fn.resolve(tmp_dir), 1, true))
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
    local expected = vim.fn.fnamemodify(SettingsGenerator.get_hook_script_path(), ":p")
    assert.equals(expected, entry.hooks[1].command)
    assert.is_true(entry.hooks[1].command:sub(1, 1) == "/", "hook command must be absolute for Grok")
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
