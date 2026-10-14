local vocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")

describe("codex_tool_vocabulary", function()
  describe("is_always_allowed", function()
    for _, name in ipairs({
      "collaborationspawn_agent",
      "collaboration.spawn_agent",
      "collaboration__spawn_agent",
      "collaborationwait_agent",
      "collaborationsend_message",
      "collaborationlist_agents",
      "functionsupdate_plan",
      "functions.exec",
      "clock.sleep",
      "image_gen.imagegen",
      "spawn_agent",
      "resume_agent",
      "close_agent",
      "request_user_input",
      "update_plan",
      "write_stdin",
    }) do
      it("recognizes built-in " .. name, function()
        assert.is_true(vocabulary.is_always_allowed(name))
      end)
    end

    for _, name in ipairs({
      "mcp__other__write",
      "mcp__vibing_nvim__nvim_get_buffer",
      "functionsmcp__other__write",
      "",
      "custom_tool",
      "mycollaborationspawn_agent",
      "Bash",
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
      "WebSearch",
      "WebFetch",
      "shell",
      "shell_command",
      "exec_command",
      "unified_exec",
      "apply_patch",
      "view_image",
      "read_file",
      "web_search",
      "webrun",
      "web.run",
      "web__run",
      "webcustom_tool",
      "functionsexec_command",
      "functions.apply_patch",
      "functionsread_file",
      "functionsweb.run",
      "functions.Bash",
      "functions__Edit",
      "functionsWebFetch",
    }) do
      it("does not grant an unrelated tool: " .. name, function()
        assert.is_false(vocabulary.is_always_allowed(name))
      end)
    end
  end)

  describe("patch diff targets", function()
    local permission = require("vibing.infrastructure.rpc.handlers.permission")

    it("extracts all operations and both move paths without mutating permission input", function()
      local input = {
        command = table.concat({
          "*** Begin Patch",
          "*** Add File: new file.txt",
          "+*** Delete File: fake.txt",
          "*** Update File: old.txt",
          "*** Move to: moved.txt",
          "@@",
          "-old",
          "+new",
          "*** Delete File: deleted.txt",
          "*** Update File: old.txt",
          "*** End Patch",
        }, "\r\n"),
      }
      local name, normalized =
        permission.normalize_hook_input({ tool_name = "functions.apply_patch", tool_input = input }, vocabulary)
      assert.equals("Edit", name)
      assert.same({ "new file.txt", "old.txt", "moved.txt", "deleted.txt" }, normalized._diff_paths)
      assert.is_nil(normalized.file_path)
      assert.is_nil(input._diff_paths)
    end)

    it("does not treat shell commands or incomplete envelopes as patch targets", function()
      local command = "*** Begin Patch\n*** Add File: a.txt\n+x\n*** End Patch"
      assert.is_nil(vocabulary.normalize_input({ command = command }, "Bash")._diff_paths)
      assert.is_nil(
        vocabulary.normalize_input({ command = "*** Begin Patch\n*** Add File: a.txt" }, "Edit")._diff_paths
      )
      assert.is_nil(vocabulary.normalize_input({ command = false }, "Edit")._diff_paths)
    end)
  end)

  describe("to_canonical", function()
    it("normalizes every shell spelling before lifecycle and command deny checks", function()
      for _, name in ipairs({ "shell", "shell_command", "exec_command", "unified_exec" }) do
        assert.equals("Bash", vocabulary.to_canonical(name))
        assert.equals("Bash", vocabulary.to_canonical("functions." .. name))
        assert.equals("Bash", vocabulary.to_canonical("functions__" .. name))
        assert.equals("Bash", vocabulary.to_canonical("functions" .. name))
      end
      assert.equals("Edit", vocabulary.to_canonical("functionsapply_patch"))
    end)
    it("maps web search tool names to WebSearch", function()
      assert.equals("WebSearch", vocabulary.to_canonical("web_search"))
      assert.equals("WebSearch", vocabulary.to_canonical("webrun"))
      assert.equals("WebSearch", vocabulary.to_canonical("web.run"))
      assert.equals("WebSearch", vocabulary.to_canonical("web__run"))
      assert.equals("WebSearch", vocabulary.to_canonical("functionsweb.run"))
    end)
    it("maps file reads and wrapped canonical names to their usual permission categories", function()
      assert.equals("Read", vocabulary.to_canonical("read_file"))
      assert.equals("Read", vocabulary.to_canonical("functionsread_file"))
      assert.equals("Read", vocabulary.to_canonical("functions.view_image"))
      assert.equals("Bash", vocabulary.to_canonical("functions.Bash"))
      assert.equals("Edit", vocabulary.to_canonical("functions__Edit"))
      assert.equals("WebFetch", vocabulary.to_canonical("functionsWebFetch"))
    end)
  end)
end)
