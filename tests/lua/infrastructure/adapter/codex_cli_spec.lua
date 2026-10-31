---@diagnostic disable: undefined-field
--- Covers the one thing codex_cli decides for itself that the command builder cannot see:
--- whether the PreToolUse hook gets registered at all.
---
--- The builder fences a lightweight call into a read-only sandbox, but the hook flag is assembled
--- in the adapter, so a spec on the builder alone would pass with the hook still wired up.

local helper = require("tests.helpers.adapter_stream")
local codex = require("vibing.infrastructure.adapter.codex_cli")
local notice = require("vibing.infrastructure.adapter.modules.codex_provider_notice")
local lightweight_provider = require("vibing.infrastructure.adapter.modules.codex_lightweight_provider")
local TurnRegistry = require("vibing.infrastructure.adapter.modules.turn_registry")

local CONFIG = {
  ai = {
    chat = {
      model = "sonnet",
    },
  },
}

--- Whether the argv carries the hook's `-c` pair.
---
--- The key is read from the generator rather than written out here on purpose. Hardcoding it once
--- already cost us: this helper spelled `hooks.pre_tool_use`, and when that turned out to be a key
--- codex ignores, the helper would have kept answering "hook registered" for a corrected argv --
--- inverting every assertion below while the suite stayed green. What this spec is for is whether
--- the adapter emits the hook at all, not how the generator spells it.
local HOOK_EVENT_KEY = require("vibing.infrastructure.hooks.codex_settings_generator")._HOOK_EVENT_KEY

local function registers_hook(cmd)
  for index, arg in ipairs(cmd) do
    if arg == "-c" and type(cmd[index + 1]) == "string" and cmd[index + 1]:find(HOOK_EVENT_KEY, 1, true) then
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
    notice._reset()
    lightweight_provider._set_config_path(false)
  end)

  after_each(function()
    system.restore()
    notice._reset()
    lightweight_provider._reset()
  end)

  it("registers the PreToolUse hook for an ordinary call", function()
    helper.run_stream(adapter, { permission_mode = "default" })
    assert.is_true(registers_hook(system.cli_call().cmd))
  end)
  it("does not enable duplex hook retry policy for codex exec", function()
    local run = helper.run_stream(adapter, { permission_mode = "default" })
    local opts = require("vibing.infrastructure.rpc.handlers.permission")._get_active_opts(run.turn_id)
    assert.same(
      { false, true, true },
      { opts._retry_hook_approval, opts._hook_approval_options == nil, opts._observe_hook_input == nil }
    )
  end)

  it("registers chat_bufnr so a waiting approval can draw into the chat", function()
    local run = helper.run_stream(adapter, { permission_mode = "default", chat_bufnr = 42 })
    local entry = TurnRegistry.get(run.turn_id)

    assert.is_not_nil(entry)
    assert.equals(42, entry.process.chat_bufnr)
    TurnRegistry.close(run.turn_id)
  end)

  it("skips it for a lightweight call, matching claude_cli", function()
    -- Routing a title-generation tool call into the chat's approval UI would prompt the user
    -- about a request they never made. The read-only sandbox is what constrains it instead.
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.is_false(registers_hook(system.cli_call().cmd))
  end)

  it("keeps it in bypassPermissions so diff capture is not bypassed too", function()
    helper.run_stream(adapter, { permission_mode = "bypassPermissions" })
    local cmd = system.cli_call().cmd
    assert.is_true(registers_hook(cmd))
    assert.is_true(vim.tbl_contains(cmd, "--dangerously-bypass-approvals-and-sandbox"))
  end)

  it("still fences the lightweight call even with the hook gone", function()
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.is_true(vim.tbl_contains(system.cli_call().cmd, 'sandbox_mode="read-only"'))
  end)

  -- The other half of that fence: --ignore-user-config takes the user's model_provider with the
  -- MCP servers it was aimed at, so the run also asks codex where it is now pointed (#587).
  it("probes for the provider the lightweight call gives up", function()
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.are.equal(2, #system.calls)
    assert.are.same({ "/usr/local/bin/codex", "doctor", "--json" }, system.calls[2].cmd)
  end)

  it("does not probe when the lightweight call reapplies the custom provider", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/config.toml"
    vim.fn.writefile({
      'model_provider = "myprov"',
      "",
      "[model_providers.myprov]",
      'name = "Local"',
      'base_url = "http://127.0.0.1:11434/v1"',
      'wire_api = "chat"',
    }, path)
    lightweight_provider._set_config_path(path)

    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.are.equal(1, #system.calls)
    local cmd = system.cli_call().cmd
    assert.is_true(vim.tbl_contains(cmd, 'model_provider="myprov"'))
    assert.is_true(vim.tbl_contains(cmd, 'model_providers.myprov.base_url="http://127.0.0.1:11434/v1"'))
    vim.fn.delete(dir, "rf")
  end)

  it("does not probe for an ordinary call, which keeps the user's provider", function()
    helper.run_stream(adapter, { permission_mode = "default" })
    assert.are.equal(1, #system.calls)
  end)

  it("carries turn.completed usage onto the response", function()
    local run = helper.run_stream(adapter, { permission_mode = "default" })
    local call = system.cli_call()
    call.opts.stdout(nil, vim.json.encode({
      type = "turn.completed",
      usage = {
        input_tokens = 120000,
        cached_input_tokens = 100000,
        cache_write_input_tokens = 500,
        output_tokens = 5000,
        reasoning_output_tokens = 3000,
      },
    }) .. "\n")
    vim.wait(200, function()
      return false
    end)
    call.on_exit({ code = 0, signal = 0 })
    vim.wait(1000, function()
      return #run.done_responses == 1
    end)

    local usage = assert(run.done_responses[1])._token_usage
    assert.equals("cumulative", usage.kind)
    assert.equals(120000, usage.totals.input)
    assert.equals(100000, usage.totals.cached)
    assert.equals(500, usage.totals.cache_write)
    assert.equals(5000, usage.totals.output)
    assert.equals(3000, usage.totals.reasoning)
  end)

  -- The prompt is the last element of the argv, so the flag scan alone would match a message
  -- that happens to be exactly that flag and warn about a loss this call never took.
  it("does not probe because the prompt looks like the flag", function()
    local opts = { permission_mode = "default", permissions_allow = {} }
    adapter:stream("--ignore-user-config", opts, function() end, function() end)
    assert.are.equal(1, #system.calls)
  end)

  it("does not probe when the notice is turned off", function()
    local off = codex:new(vim.tbl_deep_extend("force", CONFIG, {
      ai = {
        agents = {
          codex = {
            extensions = {
              provider_notice = false,
            },
          },
        },
      },
    }))
    helper.run_stream(off, { permission_mode = "default", lightweight = true })
    assert.are.equal(1, #system.calls)
  end)

  -- The default is on, so a config that never mentions the notice must still get it. CONFIG here
  -- is exactly that: an agent table with only default_model in it.
  it("probes when the config does not mention the notice at all", function()
    helper.run_stream(adapter, { permission_mode = "default", lightweight = true })
    assert.are.equal(2, #system.calls)
  end)
end)
