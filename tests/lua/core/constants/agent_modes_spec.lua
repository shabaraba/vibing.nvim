-- Tests for the agent mode enum and the validation hanging off it

local Modes = require("vibing.core.constants.modes")

describe("modes.is_valid_agent_mode", function()
  it("accepts the three documented modes", function()
    assert.is_true(Modes.is_valid_agent_mode("code"))
    assert.is_true(Modes.is_valid_agent_mode("plan"))
    assert.is_true(Modes.is_valid_agent_mode("explore"))
  end)

  it("rejects anything else", function()
    assert.is_false(Modes.is_valid_agent_mode("Code"))
    assert.is_false(Modes.is_valid_agent_mode("acceptEdits"))
    assert.is_false(Modes.is_valid_agent_mode(""))
  end)

  it("does not confuse agent modes with permission modes", function()
    -- "plan" is in both lists, but the other permission modes are not agent modes.
    assert.is_true(Modes.is_valid_permission_mode("acceptEdits"))
    assert.is_false(Modes.is_valid_agent_mode("acceptEdits"))
  end)
end)

describe("config validation of agent.default_mode", function()
  local config = require("vibing.config")

  after_each(function()
    config.setup({})
  end)

  it("keeps a valid mode", function()
    config.setup({ agent = { default_mode = "explore" } })
    assert.equals("explore", config.get().agent.default_mode)
  end)

  it("falls back to code for an unknown mode", function()
    config.setup({ agent = { default_mode = "yolo" } })
    assert.equals("code", config.get().agent.default_mode)
  end)
end)

describe("fork._copy_frontmatter", function()
  local fork = require("vibing.application.chat.use_cases.fork")
  local config = { agent = { default_mode = "code", default_model = "sonnet" } }

  it("carries a valid mode over to the fork", function()
    local copied = fork._copy_frontmatter({ mode = "explore" }, "source.md", config)
    assert.equals("explore", copied.mode)
  end)

  it("resets an invalid mode instead of propagating it into the fork", function()
    local copied = fork._copy_frontmatter({ mode = "planning" }, "source.md", config)
    assert.equals("code", copied.mode)
  end)

  it("falls back to the configured default when the source has no mode", function()
    local copied = fork._copy_frontmatter({}, "source.md", { agent = { default_mode = "plan" } })
    assert.equals("plan", copied.mode)
  end)
end)

describe("send_message._validate_frontmatter_mode", function()
  local SendMessage = require("vibing.application.chat.send_message")

  it("passes a valid mode through", function()
    assert.equals("plan", SendMessage._validate_frontmatter_mode("plan"))
  end)

  it("returns nil when no mode is set", function()
    assert.is_nil(SendMessage._validate_frontmatter_mode(nil))
  end)

  it("drops an unknown mode instead of forwarding it silently", function()
    assert.is_nil(SendMessage._validate_frontmatter_mode("planning"))
  end)

  it("warns only once for the same typo, since execute runs per message", function()
    local warned = 0
    local original = vim.notify
    vim.notify = function()
      warned = warned + 1
    end

    SendMessage._validate_frontmatter_mode("repeated-typo")
    SendMessage._validate_frontmatter_mode("repeated-typo")
    SendMessage._validate_frontmatter_mode("repeated-typo")

    vim.notify = original
    assert.equals(1, warned)
  end)

  it("dedupes the warning for a non-string mode too", function()
    -- tostring() of a table is its address, so a fresh table each parse would warn every time.
    local warned = 0
    local original = vim.notify
    vim.notify = function()
      warned = warned + 1
    end

    SendMessage._validate_frontmatter_mode({ "a", "b" })
    SendMessage._validate_frontmatter_mode({ "c", "d" })

    vim.notify = original
    assert.equals(1, warned)
  end)

  it("drops a non-string mode", function()
    assert.is_nil(SendMessage._validate_frontmatter_mode(42))
  end)
end)
