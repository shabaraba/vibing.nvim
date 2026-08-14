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

    it("maps todo_write onto TodoWrite, which is always-allowed", function()
      -- Unmapped, the raw name reaches can_use_tool, misses the INTERNAL_TOOLS list (which holds
      -- the capitalised spelling) and resolves to `ask` -- an approval prompt for a bookkeeping
      -- tool. A lightweight utility call has no UI to show that prompt in and gets killed by
      -- cancel_and_deny instead, so this mapping is what keeps title generation working on a
      -- project whose .grok/hooks/ an earlier ordinary chat already wrote.
      assert.equals("TodoWrite", vocabulary.to_canonical("todo_write"))
    end)

    it("returns nil for a name it does not know, so the caller keeps the original", function()
      assert.is_nil(vocabulary.to_canonical("Bash"))
      assert.is_nil(vocabulary.to_canonical("something_new"))
    end)
  end)

  describe("normalize_payload", function()
    -- Captured from grok 0.2.101's PreToolUse hook, not hand-written.
    local GROK_PAYLOAD = {
      hookEventName = "pre_tool_use",
      sessionId = "019ff868-db76-7d22-80d1-3530826638aa",
      toolName = "read_file",
      toolUseId = "call-c2935dd2-d4e9-4626-81a3-7732aecd6ab8-0",
      toolInput = { target_file = "README.md" },
      permissionMode = "auto",
    }

    it("exposes Grok's camelCase payload under the snake_case keys the handler reads", function()
      local out = vocabulary.normalize_payload(GROK_PAYLOAD)
      assert.equals("read_file", out.tool_name)
      assert.same({ target_file = "README.md" }, out.tool_input)
    end)

    it("keeps the fields the approval UI still needs", function()
      local out = vocabulary.normalize_payload(GROK_PAYLOAD)
      assert.equals("019ff868-db76-7d22-80d1-3530826638aa", out.sessionId)
      assert.equals("pre_tool_use", out.hookEventName)
    end)

    it("does not mutate the original", function()
      local payload = vim.deepcopy(GROK_PAYLOAD)
      vocabulary.normalize_payload(payload)
      assert.is_nil(payload.tool_name)
    end)

    it("leaves a payload that already speaks snake_case alone", function()
      local payload = { tool_name = "read_file", tool_input = { file_path = "a.lua" }, toolName = "ignored" }
      assert.equals("read_file", vocabulary.normalize_payload(payload).tool_name)
    end)

    it("defaults tool_input to a table when Grok sends a tool with no input", function()
      assert.same({}, vocabulary.normalize_payload({ toolName = "list_dir" }).tool_input)
    end)

    it("passes through anything that is neither shape", function()
      assert.same({ other = 1 }, vocabulary.normalize_payload({ other = 1 }))
      assert.equals("nope", vocabulary.normalize_payload("nope"))
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
