---@diagnostic disable: undefined-field
local Modes = require("vibing.core.constants.modes")
local cli_command_builder = require("vibing.infrastructure.adapter.modules.cli_command_builder")

local function find_flag(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return i
    end
  end
  return nil
end

describe("effort levels", function()
  it("matches what claude --effort accepts", function()
    -- Verified against claude CLI 2.1.220: --effort <level> (low, medium, high, xhigh, max).
    assert.same({ "low", "medium", "high", "xhigh", "max" }, Modes.EFFORT_LEVELS)
  end)

  it("validates a level", function()
    assert.is_true(Modes.is_valid_effort("xhigh"))
    assert.is_false(Modes.is_valid_effort("extreme"))
    assert.is_false(Modes.is_valid_effort(nil))
  end)
end)

describe("cli_command_builder --effort", function()
  it("passes nothing when no effort is configured", function()
    -- The CLI's own default applies, and that default moves as Anthropic tunes it.
    local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
    assert.is_nil(find_flag(cmd, "--effort"))
  end)

  it("passes the chat's effort", function()
    local cmd = cli_command_builder.build("hello", { effort = "xhigh" }, nil, {}, nil)
    local idx = find_flag(cmd, "--effort")
    assert.is_not_nil(idx)
    assert.equals("xhigh", cmd[idx + 1])
  end)

  it("falls back to config.agent.default_effort", function()
    local config = { agent = { default_effort = "high" } }
    local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
    assert.equals("high", cmd[find_flag(cmd, "--effort") + 1])
  end)

  it("prefers the chat's effort over the configured default", function()
    local config = { agent = { default_effort = "high" } }
    local cmd = cli_command_builder.build("hello", { effort = "low" }, nil, config, nil)
    assert.equals("low", cmd[find_flag(cmd, "--effort") + 1])
  end)

  it("uses utility_effort for lightweight calls, ignoring the chat's effort", function()
    -- Pairs with utility_model: title generation and summaries get the cheap model AND the cheap
    -- effort, rather than inheriting whatever the conversation was set to.
    local config = { agent = { default_effort = "max", utility_effort = "low" } }
    local cmd = cli_command_builder.build("hello", { lightweight = true, effort = "max" }, nil, config, nil)
    assert.equals("low", cmd[find_flag(cmd, "--effort") + 1])
  end)

  it("drops an unknown level rather than passing it through", function()
    -- The CLI accepts an unknown level without complaint and then ignores it, so a typo would
    -- otherwise silently do nothing.
    local notify = require("vibing.core.utils.notify")
    local original_warn = notify.warn
    local warned = nil
    notify.warn = function(message)
      warned = message
    end

    local cmd = cli_command_builder.build("hello", { effort = "extreme" }, nil, {}, nil)

    notify.warn = original_warn
    assert.is_nil(find_flag(cmd, "--effort"))
    assert.is_not_nil(warned)
    assert.is_true(warned:find("extreme", 1, true) ~= nil)
  end)

  it("sits next to --model so both tiers are visible together", function()
    local config = { agent = { default_model = "opus", default_effort = "xhigh" } }
    local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
    assert.equals("opus", cmd[find_flag(cmd, "--model") + 1])
    assert.equals("xhigh", cmd[find_flag(cmd, "--effort") + 1])
  end)
end)
