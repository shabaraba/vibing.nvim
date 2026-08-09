describe("settings_generator", function()
  local SettingsGenerator = require("vibing.infrastructure.hooks.settings_generator")

  it("points both hooks at scripts bundled with the plugin", function()
    local pre_tool_use = SettingsGenerator.get_hook_script_path()
    local stop_failure = SettingsGenerator.get_stop_failure_script_path()

    assert.truthy(pre_tool_use:match("/bin/hooks/pre%-tool%-use%.sh$"))
    assert.truthy(stop_failure:match("/bin/hooks/stop%-failure%.sh$"))
    -- Resolved from the plugin's own location, so the path survives an install-dir change.
    assert.equals(1, vim.fn.filereadable(pre_tool_use))
    assert.equals(1, vim.fn.filereadable(stop_failure))
    assert.equals(1, vim.fn.executable(pre_tool_use))
    assert.equals(1, vim.fn.executable(stop_failure))
  end)

  it("registers a PreToolUse hook matching every tool", function()
    local settings = SettingsGenerator.generate()
    local entry = settings.hooks.PreToolUse[1]

    assert.equals(".*", entry.matcher)
    assert.equals("command", entry.hooks[1].type)
    assert.equals(SettingsGenerator.get_hook_script_path(), entry.hooks[1].command)
  end)

  it("registers a StopFailure hook scoped to rate_limit errors", function()
    local settings = SettingsGenerator.generate()
    local entry = settings.hooks.StopFailure[1]

    -- Only rate_limit carries a reset time worth waiting for; other API errors (overloaded,
    -- billing_error, ...) would park a chat that can never be resumed on a schedule.
    assert.equals("rate_limit", entry.matcher)
    assert.equals(SettingsGenerator.get_stop_failure_script_path(), entry.hooks[1].command)
  end)

  it("writes an absolute settings path under the given cwd", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")

    local path = SettingsGenerator.ensure(tmp)

    assert.equals(tmp .. "/.vibing/hook-settings.json", path)
    assert.equals(1, vim.fn.filereadable(path))

    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.is_not_nil(decoded.hooks.PreToolUse)
    assert.is_not_nil(decoded.hooks.StopFailure)

    vim.fn.delete(tmp, "rf")
  end)

  it("regenerates the settings file on every call", function()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")

    local path = SettingsGenerator.ensure(tmp)
    vim.fn.writefile({ "{}" }, path)
    SettingsGenerator.ensure(tmp)

    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.is_not_nil(decoded.hooks)

    vim.fn.delete(tmp, "rf")
  end)
end)
