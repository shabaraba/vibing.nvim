-- Tests for vibing.config module

describe("vibing.config", function()
  local config

  before_each(function()
    -- Reload module before each test
    package.loaded["vibing.config"] = nil
    config = require("vibing.config")
  end)

  describe("defaults", function()
    it("should have chat configuration", function()
      assert.is_not_nil(config.defaults.chat)
      assert.is_not_nil(config.defaults.chat.window)
      assert.equals("current", config.defaults.chat.window.position)
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
      assert.is_not_nil(config.defaults.permissions.rules)
      assert.is_table(config.defaults.permissions.rules)
    end)

    it("should have language configuration", function()
      assert.is_nil(config.defaults.language)
    end)
  end)

  describe("setup", function()
    it("should merge user config with defaults", function()
      local user_config = {
        chat = {
          window = {
            position = "left",
          },
        },
      }

      config.setup(user_config)
      local result = config.get()

      -- User values should override defaults
      assert.equals("left", result.chat.window.position)

      -- Non-overridden defaults should remain
      assert.is_not_nil(result.agent)
      assert.equals("code", result.agent.default_mode)
    end)

    it("should warn about invalid tools in permissions", function()
      local user_config = {
        permissions = {
          allow = { "Read", "InvalidTool" },
        },
      }
      -- Should not error, just warn
      assert.has_no.errors(function()
        config.setup(user_config)
      end)
    end)
  end)

  describe("get", function()
    it("should return current config", function()
      config.setup({
        agent = {
          default_mode = "plan"
        }
      })
      local result = config.get()
      assert.equals("plan", result.agent.default_mode)
    end)
  end)
end)
