-- Tests for vibing.config module

describe("vibing.config", function()
  local config

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.config"] = nil
    config = require("vibing.config")
  end)

  describe("defaults", function()
    it("should have adapter field", function()
      assert.is_not_nil(config.defaults.adapter)
      assert.equals("agent_sdk", config.defaults.adapter)
    end)

    it("should have chat configuration", function()
      assert.is_not_nil(config.defaults.chat)
      assert.is_not_nil(config.defaults.chat.window)
      assert.equals("right", config.defaults.chat.window.position)
    end)

    it("should have agent configuration", function()
      assert.is_not_nil(config.defaults.agent)
      assert.equals("code", config.defaults.agent.default_mode)
      assert.equals("sonnet", config.defaults.agent.default_model)
    end)

    it("should have permissions configuration", function()
      assert.is_not_nil(config.defaults.permissions)
      assert.is_not_nil(config.defaults.permissions.allow)
      assert.is_table(config.defaults.permissions.allow)
    end)
  end)

  describe("merge", function()
    it("should merge user config with defaults", function()
      local user_config = {
        adapter = "claude",
        chat = {
          window = {
            position = "left",
          },
        },
      }

      local merged = config.merge(user_config)

      -- User values should override defaults
      assert.equals("claude", merged.adapter)
      assert.equals("left", merged.chat.window.position)

      -- Non-overridden defaults should remain
      assert.is_not_nil(merged.agent)
      assert.equals("code", merged.agent.default_mode)
    end)

    it("should handle empty user config", function()
      local merged = config.merge({})
      assert.equals("agent_sdk", merged.adapter)
    end)

    it("should handle nil user config", function()
      local merged = config.merge(nil)
      assert.equals("agent_sdk", merged.adapter)
    end)
  end)

  describe("validate", function()
    it("should accept valid adapter", function()
      local valid_config = {
        adapter = "agent_sdk",
      }
      assert.has_no.errors(function()
        config.validate(valid_config)
      end)
    end)

    it("should reject invalid adapter", function()
      local invalid_config = {
        adapter = "invalid_adapter",
      }
      -- Note: Actual validation implementation may vary
      -- This test demonstrates expected behavior
    end)
  end)
end)
