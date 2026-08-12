describe("grok_tool_vocabulary", function()
  local vocabulary = require("vibing.infrastructure.adapter.modules.grok_tool_vocabulary")

  describe("to_canonical", function()
    it("translates Grok's names to the ones the permission rules are written in", function()
      assert.equals("Bash", vocabulary.to_canonical("run_terminal_command"))
      assert.equals("Read", vocabulary.to_canonical("read_file"))
      assert.equals("Write", vocabulary.to_canonical("write_file"))
      assert.equals("Grep", vocabulary.to_canonical("grep"))
      assert.equals("Task", vocabulary.to_canonical("spawn_subagent"))
    end)

    it("maps every edit spelling Grok uses onto Edit", function()
      -- A deny rule on Edit has to catch all three, or one of them silently writes files.
      assert.equals("Edit", vocabulary.to_canonical("search_replace"))
      assert.equals("Edit", vocabulary.to_canonical("edit_file"))
      assert.equals("Edit", vocabulary.to_canonical("apply_patch"))
    end)

    it("maps every shell spelling onto Bash", function()
      assert.equals("Bash", vocabulary.to_canonical("bash"))
      assert.equals("Bash", vocabulary.to_canonical("shell"))
    end)

    it("returns nil for a name it does not know, so the caller keeps the original", function()
      assert.is_nil(vocabulary.to_canonical("Bash"))
      assert.is_nil(vocabulary.to_canonical("something_new"))
    end)
  end)

  describe("normalize_input", function()
    it("fills in file_path from the keys Grok actually uses", function()
      -- Granular `paths` rules read file_path; without this they match nothing on Grok.
      assert.equals("a.lua", vocabulary.normalize_input({ path = "a.lua" }).file_path)
      assert.equals("b.lua", vocabulary.normalize_input({ target_file = "b.lua" }).file_path)
      assert.equals("c.lua", vocabulary.normalize_input({ filePath = "c.lua" }).file_path)
    end)

    it("leaves an input that already names file_path alone", function()
      local input = { file_path = "kept.lua", path = "ignored.lua" }
      assert.equals("kept.lua", vocabulary.normalize_input(input).file_path)
    end)

    it("does not mutate the original, which is also what the approval UI renders", function()
      local input = { path = "a.lua" }
      vocabulary.normalize_input(input)
      assert.is_nil(input.file_path)
    end)

    it("passes through an input with no path at all", function()
      assert.same({ command = "ls" }, vocabulary.normalize_input({ command = "ls" }))
      assert.equals("nope", vocabulary.normalize_input("nope"))
    end)
  end)
end)
