---@diagnostic disable: undefined-field
local Vocabulary = require("vibing.infrastructure.adapter.modules.copilot_tool_vocabulary")

describe("copilot_tool_vocabulary", function()
  before_each(function()
    Vocabulary._reset_unmapped_warnings()
  end)

  describe("to_canonical", function()
    it("maps copilot native tool names onto the canonical vocabulary", function()
      assert.are.equal("Bash", Vocabulary.to_canonical("bash"))
      assert.are.equal("Read", Vocabulary.to_canonical("view"))
      assert.are.equal("Write", Vocabulary.to_canonical("create"))
      assert.are.equal("Edit", Vocabulary.to_canonical("edit"))
      assert.are.equal("WebSearch", Vocabulary.to_canonical("web_search"))
    end)

    it("returns nil for a name it has no mapping for", function()
      assert.is_nil(Vocabulary.to_canonical("something_new"))
    end)
  end)

  describe("to_deny_pattern", function()
    it("maps Bash to shell", function()
      assert.are.equal("shell", Vocabulary.to_deny_pattern("Bash"))
    end)

    it("maps Bash(npm:*) to shell(npm:*)", function()
      assert.are.equal("shell(npm:*)", Vocabulary.to_deny_pattern("Bash(npm:*)"))
    end)

    it("maps Write and Edit to write", function()
      assert.are.equal("write", Vocabulary.to_deny_pattern("Write"))
      assert.are.equal("write", Vocabulary.to_deny_pattern("Edit"))
    end)

    it("maps WebFetch and WebSearch to url", function()
      assert.are.equal("url", Vocabulary.to_deny_pattern("WebFetch"))
      assert.are.equal("url", Vocabulary.to_deny_pattern("WebSearch"))
    end)

    it("returns nil for unmapped tools", function()
      assert.is_nil(Vocabulary.to_deny_pattern("Read"))
      assert.is_nil(Vocabulary.to_deny_pattern("Glob"))
    end)
  end)

  describe("build_deny_patterns", function()
    it("deduplicates write from Write and Edit", function()
      local patterns = Vocabulary.build_deny_patterns({ "Write", "Edit", "Bash" })
      assert.are.same({ "write", "shell" }, patterns)
    end)

    it("returns an empty list for nil", function()
      assert.are.same({}, Vocabulary.build_deny_patterns(nil))
    end)

    it("warns once per unsupported entry instead of dropping it silently", function()
      Vocabulary._reset_unmapped_warnings()
      local messages = {}
      local original_notify = vim.notify
      vim.notify = function(msg)
        table.insert(messages, msg)
      end

      local first = Vocabulary.build_deny_patterns({ "Grep", "Bash" })
      local second = Vocabulary.build_deny_patterns({ "Grep" })

      vim.notify = original_notify
      Vocabulary._reset_unmapped_warnings()

      assert.are.same({ "shell" }, first)
      assert.are.same({}, second)
      assert.are.equal(1, #messages)
      assert.is_true(messages[1]:find("Grep", 1, true) ~= nil)
    end)
  end)

end)
