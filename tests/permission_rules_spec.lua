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

end)
