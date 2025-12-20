-- Tests for granular permission rules

describe("vibing granular permission rules", function()
  describe("config integration", function()
    it("should accept permission rules in config", function()
      local config = require("vibing.config")

      local user_config = {
        permissions = {
          allow = { "Read", "Write" },
          deny = {},
          rules = {
            {
              tools = { "Read" },
              paths = { "src/**" },
              action = "allow",
            },
            {
              tools = { "Read", "Write" },
              paths = { "/etc/**" },
              action = "deny",
              message = "System files are protected",
            },
          },
        },
      }

      config.setup(user_config)
      local result = config.get()

      assert.is_not_nil(result.permissions.rules)
      assert.is_table(result.permissions.rules)
      assert.equals(2, #result.permissions.rules)

      -- Check first rule
      assert.is_table(result.permissions.rules[1].tools)
      assert.equals("Read", result.permissions.rules[1].tools[1])
      assert.is_table(result.permissions.rules[1].paths)
      assert.equals("src/**", result.permissions.rules[1].paths[1])
      assert.equals("allow", result.permissions.rules[1].action)

      -- Check second rule
      assert.equals("deny", result.permissions.rules[2].action)
      assert.equals("System files are protected", result.permissions.rules[2].message)
    end)

    it("should handle Bash command rules", function()
      local config = require("vibing.config")

      local user_config = {
        permissions = {
          allow = { "Bash" },
          rules = {
            {
              tools = { "Bash" },
              commands = { "npm", "yarn", "make" },
              action = "allow",
            },
            {
              tools = { "Bash" },
              patterns = { "^rm -rf", "^sudo" },
              action = "deny",
              message = "Dangerous commands are not allowed",
            },
          },
        },
      }

      config.setup(user_config)
      local result = config.get()

      assert.equals(2, #result.permissions.rules)

      -- Check command allow list
      assert.is_table(result.permissions.rules[1].commands)
      assert.equals("npm", result.permissions.rules[1].commands[1])
      assert.equals("yarn", result.permissions.rules[1].commands[2])

      -- Check pattern deny list
      assert.is_table(result.permissions.rules[2].patterns)
      assert.equals("^rm -rf", result.permissions.rules[2].patterns[1])
      assert.equals("^sudo", result.permissions.rules[2].patterns[2])
    end)

    it("should handle URL/domain rules", function()
      local config = require("vibing.config")

      local user_config = {
        permissions = {
          allow = { "WebFetch" },
          rules = {
            {
              tools = { "WebFetch" },
              domains = { "github.com", "npmjs.com", "*.example.com" },
              action = "allow",
            },
          },
        },
      }

      config.setup(user_config)
      local result = config.get()

      assert.equals(1, #result.permissions.rules)
      assert.is_table(result.permissions.rules[1].domains)
      assert.equals("github.com", result.permissions.rules[1].domains[1])
      assert.equals("*.example.com", result.permissions.rules[1].domains[3])
    end)
  end)

  describe("agent_sdk adapter integration", function()
    it("should pass rules to agent-wrapper via --rules parameter", function()
      -- Reload modules to ensure clean state
      package.loaded["vibing"] = nil
      package.loaded["vibing.config"] = nil
      package.loaded["vibing.adapters.agent_sdk"] = nil

      local vibing = require("vibing")
      local agent_sdk = require("vibing.adapters.agent_sdk")

      -- Setup config with rules via vibing.setup()
      vibing.setup({
        permissions = {
          allow = { "Read" },
          rules = {
            {
              tools = { "Read" },
              paths = { "src/**" },
              action = "allow",
            },
          },
        },
      })

      local adapter = agent_sdk:new(vibing.get_config())
      local cmd = adapter:build_command("test prompt", {})

      -- Check that --rules is in command
      local has_rules_flag = false
      local rules_json = nil
      for i, arg in ipairs(cmd) do
        if arg == "--rules" and cmd[i + 1] then
          has_rules_flag = true
          rules_json = cmd[i + 1]
        end
      end

      assert.is_true(has_rules_flag)
      assert.is_not_nil(rules_json)

      -- Verify JSON is valid
      local success, decoded = pcall(vim.json.decode, rules_json)
      assert.is_true(success)
      assert.is_table(decoded)
      assert.equals(1, #decoded)
    end)

    it("should not add --rules if no rules are configured", function()
      -- Reload modules to ensure clean state
      package.loaded["vibing"] = nil
      package.loaded["vibing.config"] = nil
      package.loaded["vibing.adapters.agent_sdk"] = nil

      local vibing = require("vibing")
      local agent_sdk = require("vibing.adapters.agent_sdk")

      vibing.setup({
        permissions = {
          allow = { "Read" },
          rules = {},
        },
      })

      local adapter = agent_sdk:new(vibing.get_config())
      local cmd = adapter:build_command("test prompt", {})

      -- Check that --rules is NOT in command
      local has_rules_flag = false
      for _, arg in ipairs(cmd) do
        if arg == "--rules" then
          has_rules_flag = true
        end
      end

      assert.is_false(has_rules_flag)
    end)
  end)
end)
