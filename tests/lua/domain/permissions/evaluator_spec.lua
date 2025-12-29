local evaluator = require("vibing.domain.permissions.evaluator")

describe("permission evaluator", function()
  describe("allow list check (UT-PERM-001)", function()
    it("should allow tool in allow list", function()
      local config = { allow = { "Read", "Edit" }, deny = {} }
      local result = evaluator.evaluate("Read", {}, config)

      assert.is_true(result.allowed)
    end)

    it("should deny tool not in allow list", function()
      local config = { allow = { "Read", "Edit" }, deny = {} }
      local result = evaluator.evaluate("Bash", {}, config)

      assert.is_false(result.allowed)
    end)

    it("should allow any tool when allow list is empty", function()
      local config = { allow = {}, deny = {} }
      local result = evaluator.evaluate("Read", {}, config)

      assert.is_true(result.allowed)
    end)
  end)

  describe("deny list precedence (UT-PERM-002)", function()
    it("should deny tool in deny list even if in allow list", function()
      local config = { allow = { "Bash" }, deny = { "Bash" } }
      local result = evaluator.evaluate("Bash", {}, config)

      assert.is_false(result.allowed)
      assert.is_not_nil(result.reason)
    end)

    it("should deny tool in deny list only", function()
      local config = { allow = {}, deny = { "Bash" } }
      local result = evaluator.evaluate("Bash", {}, config)

      assert.is_false(result.allowed)
    end)
  end)

  describe("path-based rules (UT-PERM-003)", function()
    it("should allow Read for matching path pattern", function()
      local rules = {
        { tools = { "Read" }, paths = { "src/**" }, action = "allow" },
      }
      local result = evaluator.evaluate_with_rules("Read", { path = "src/init.lua" }, rules)

      assert.is_true(result.allowed)
    end)

    it("should deny Read for denied path pattern", function()
      local rules = {
        { tools = { "Read" }, paths = { "src/**" }, action = "allow" },
        { tools = { "Read" }, paths = { ".env*" }, action = "deny" },
      }
      local result = evaluator.evaluate_with_rules("Read", { path = ".env.local" }, rules)

      assert.is_false(result.allowed)
    end)

    it("should deny Read for non-matching path", function()
      local rules = {
        { tools = { "Read" }, paths = { "src/**" }, action = "allow" },
      }
      local result = evaluator.evaluate_with_rules("Read", { path = "tests/test.lua" }, rules)

      assert.is_false(result.allowed)
    end)
  end)

  describe("command pattern rules (UT-PERM-004)", function()
    it("should allow npm command when in allowed commands", function()
      local rules = {
        { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },
      }
      local result = evaluator.evaluate_with_rules("Bash", { command = "npm install" }, rules)

      assert.is_true(result.allowed)
    end)

    it("should allow yarn command when in allowed commands", function()
      local rules = {
        { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },
      }
      local result = evaluator.evaluate_with_rules("Bash", { command = "yarn build" }, rules)

      assert.is_true(result.allowed)
    end)

    it("should deny command matching dangerous pattern", function()
      local rules = {
        { tools = { "Bash" }, patterns = { "^rm %-rf", "^sudo" }, action = "deny" },
      }
      local result = evaluator.evaluate_with_rules("Bash", { command = "rm -rf /" }, rules)

      assert.is_false(result.allowed)
    end)

    it("should deny sudo command matching pattern", function()
      local rules = {
        { tools = { "Bash" }, patterns = { "^sudo" }, action = "deny" },
      }
      local result = evaluator.evaluate_with_rules("Bash", { command = "sudo apt install" }, rules)

      assert.is_false(result.allowed)
    end)

    it("should deny command not in allowed list", function()
      local rules = {
        { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },
      }
      local result = evaluator.evaluate_with_rules("Bash", { command = "ls -la" }, rules)

      assert.is_false(result.allowed)
    end)
  end)

  describe("rule priority", function()
    it("should apply deny rules first", function()
      local rules = {
        { tools = { "Read" }, paths = { "**" }, action = "allow" },
        { tools = { "Read" }, paths = { ".env*" }, action = "deny" },
      }
      local result = evaluator.evaluate_with_rules("Read", { path = ".env" }, rules)

      assert.is_false(result.allowed)
    end)
  end)
end)
