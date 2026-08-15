---@diagnostic disable: undefined-field
--- Covers the one thing grok_cli decides for itself that the command builder cannot see:
--- whether the PreToolUse hook gets installed at all.
---
--- The builder cuts a lightweight call down to a single inert tool, but the hook is written to
--- disk by the adapter, so a spec on the builder alone would pass with the hook still wired up.
--- Unlike codex the hook is not an argv flag here -- grok discovers `<cwd>/.grok/hooks/` -- so
--- this asserts on the generator being called rather than on the command array.

local helper = require("tests.helpers.adapter_stream")
local GrokSettingsGenerator = require("vibing.infrastructure.hooks.grok_settings_generator")
local grok = require("vibing.infrastructure.adapter.grok_cli")

local CONFIG = { agent = { default_model = "sonnet" } }

describe("grok_cli hook registration", function()
  local system, adapter, ensure_calls, original_ensure, original_executable

  before_each(function()
    system = helper.stub_system("/usr/local/bin/grok")

    -- The builder sniffs the binary to confirm it is the official CLI; reporting it as
    -- non-executable skips that without needing grok on the machine.
    original_executable = vim.fn.executable
    vim.fn.executable = function(path)
      if path == "/usr/local/bin/grok" then
        return 0
      end
      return original_executable(path)
    end

    ensure_calls = 0
    original_ensure = GrokSettingsGenerator.ensure
    GrokSettingsGenerator.ensure = function()
      ensure_calls = ensure_calls + 1
    end

    adapter = grok:new(CONFIG)
  end)

  after_each(function()
    GrokSettingsGenerator.ensure = original_ensure
    vim.fn.executable = original_executable
    system.restore()
  end)

  it("installs the PreToolUse hook for an ordinary call", function()
    helper.run_stream(adapter, { permission_mode = "default" })
    assert.equals(1, ensure_calls)
  end)

  it("skips it for a lightweight call, matching claude_cli and codex_cli", function()
    -- Routing a title-generation tool call into the chat's approval UI would prompt the user
    -- about a request they never made. The tool allowlist is what constrains it instead.
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.equals(0, ensure_calls)
  end)

  it("skips it in bypassPermissions, as before", function()
    helper.run_stream(adapter, { permission_mode = "bypassPermissions" })
    assert.equals(0, ensure_calls)
  end)

  it("still restricts the lightweight call even with the hook gone", function()
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    local cmd = system.only_call().cmd
    assert.is_true(vim.tbl_contains(cmd, "todo_write"))
  end)
end)
