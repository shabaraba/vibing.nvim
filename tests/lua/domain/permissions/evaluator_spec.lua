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

  describe("path normalization security (UT-PERM-005)", function()
    it("should normalize relative paths to absolute", function()
      local rules = {
        { tools = { "Read" }, paths = { vim.fn.getcwd() .. "/src/**" }, action = "allow" },
      }
      -- Relative path should be normalized and matched
      local result = evaluator.evaluate_with_rules("Read", { path = "src/init.lua" }, rules)

      assert.is_true(result.allowed)
    end)

    it("should resolve symlinks in paths", function()
      -- Create a temporary file and symlink for testing
      local tmpfile = vim.fn.tempname()
      local tmplink = vim.fn.tempname() .. "_link"

      -- Write test file
      vim.fn.writefile({ "test" }, tmpfile)

      -- Create symlink (if possible on this system)
      local link_result = vim.fn.system("ln -s " .. tmpfile .. " " .. tmplink)

      if vim.v.shell_error == 0 then
        local rules = {
          { tools = { "Read" }, paths = { tmpfile }, action = "deny" },
        }

        -- Access via symlink should also be denied
        local result = evaluator.evaluate_with_rules("Read", { path = tmplink }, rules)

        assert.is_false(result.allowed)

        -- Cleanup
        vim.fn.delete(tmplink)
      end

      -- Cleanup
      vim.fn.delete(tmpfile)
    end)

    it("should handle tilde expansion in patterns", function()
      local rules = {
        { tools = { "Read" }, paths = { "~/.config/**" }, action = "allow" },
      }

      local home_path = vim.fn.expand("~/.config/nvim/init.lua")
      local result = evaluator.evaluate_with_rules("Read", { path = home_path }, rules)

      assert.is_true(result.allowed)
    end)
  end)
end)
