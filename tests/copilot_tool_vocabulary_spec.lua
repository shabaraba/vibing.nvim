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

    it("covers the search and fetch tools, which permission rules name canonically", function()
      -- Unmapped names reach can_use_tool verbatim, so a `Grep` entry in allow/ask/deny would
      -- never match copilot's `grep` and the rule would silently do nothing.
      assert.are.equal("Grep", Vocabulary.to_canonical("grep"))
      assert.are.equal("Grep", Vocabulary.to_canonical("rg"))
      assert.are.equal("Glob", Vocabulary.to_canonical("glob"))
      assert.are.equal("WebFetch", Vocabulary.to_canonical("web_fetch"))
      assert.are.equal("Bash", Vocabulary.to_canonical("powershell"))
      assert.are.equal("Task", Vocabulary.to_canonical("task"))
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

  describe("normalize_payload", function()
    -- Shape captured from copilot 1.0.78's preToolUse hook, not read off its docs.
    it("renames toolName/toolArgs and decodes the arguments, which arrive as a JSON string", function()
      local normalized = Vocabulary.normalize_payload({
        sessionId = "s-1",
        cwd = "/proj",
        toolName = "bash",
        toolArgs = '{"command":"echo hi","description":"greet"}',
      })

      assert.are.equal("bash", normalized.tool_name)
      assert.are.equal("echo hi", normalized.tool_input.command)
    end)

    it("accepts arguments that already arrived decoded", function()
      local normalized = Vocabulary.normalize_payload({ toolName = "view", toolArgs = { path = "a.lua" } })
      assert.are.equal("a.lua", normalized.tool_input.path)
    end)

    it("yields an empty input rather than failing when toolArgs is not JSON", function()
      -- A tool whose arguments cannot be read still has to reach a permission decision; the
      -- alternative is an error inside the handler and a turn that hangs until the hook denies.
      local normalized = Vocabulary.normalize_payload({ toolName = "bash", toolArgs = "not json" })
      assert.are.equal("bash", normalized.tool_name)
      assert.are.same({}, normalized.tool_input)
    end)

    it("leaves a payload that already speaks the canonical shape alone", function()
      local input = { tool_name = "Read", tool_input = { file_path = "a.lua" } }
      assert.are.same(input, Vocabulary.normalize_payload(input))
    end)

    it("does not mutate the payload it was given", function()
      local input = { toolName = "bash", toolArgs = '{"command":"ls"}' }
      Vocabulary.normalize_payload(input)
      assert.is_nil(input.tool_name)
    end)
  end)

  describe("normalize_input", function()
    it("fills in file_path from copilot's path key, which granular rules read", function()
      assert.are.equal("a.lua", Vocabulary.normalize_input({ path = "a.lua" }).file_path)
    end)

    it("keeps an existing file_path", function()
      local input = Vocabulary.normalize_input({ file_path = "kept.lua", path = "other.lua" })
      assert.are.equal("kept.lua", input.file_path)
    end)

    it("leaves an input with no path alone", function()
      assert.are.same({ command = "ls" }, Vocabulary.normalize_input({ command = "ls" }))
    end)
  end)
end)
