---@diagnostic disable: undefined-field
--- Covers the one thing codex_cli decides for itself that the command builder cannot see:
--- whether the PreToolUse hook gets registered at all.
---
--- The builder fences a lightweight call into a read-only sandbox, but the hook flag is assembled
--- in the adapter, so a spec on the builder alone would pass with the hook still wired up.

local helper = require("tests.helpers.adapter_stream")
local codex = require("vibing.infrastructure.adapter.codex_cli")

local CONFIG = { agent = { default_model = "sonnet" } }

--- Whether the argv carries a `-c hooks.pre_tool_use=...` pair.
local function registers_hook(cmd)
  for index, arg in ipairs(cmd) do
    if arg == "-c" and type(cmd[index + 1]) == "string" and cmd[index + 1]:find("hooks.pre_tool_use", 1, true) then
      return true
    end
  end
  return false
end

describe("codex_cli hook registration", function()
  local system, adapter

  before_each(function()
    system = helper.stub_system("/usr/local/bin/codex")
    adapter = codex:new(CONFIG)
  end)

  after_each(function()
    system.restore()
  end)

  it("registers the PreToolUse hook for an ordinary call", function()
    helper.run_stream(adapter, { permission_mode = "default" })
    assert.is_true(registers_hook(system.only_call().cmd))
  end)

  it("skips it for a lightweight call, matching claude_cli", function()
    -- Routing a title-generation tool call into the chat's approval UI would prompt the user
    -- about a request they never made. The read-only sandbox is what constrains it instead.
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.is_false(registers_hook(system.only_call().cmd))
  end)

  it("skips it in bypassPermissions, as before", function()
    helper.run_stream(adapter, { permission_mode = "bypassPermissions" })
    assert.is_false(registers_hook(system.only_call().cmd))
  end)

  it("still fences the lightweight call even with the hook gone", function()
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.is_true(vim.tbl_contains(system.only_call().cmd, 'sandbox_mode="read-only"'))
  end)
end)
