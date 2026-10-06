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
      "webrun",
      "image_gen.imagegen",
      "spawn_agent",
      "resume_agent",
      "close_agent",
      "request_user_input",
      "update_plan",
      "Bash",
      "Edit",
      "Write",
      "WebSearch",
      "apply_patch",
      "exec_command",
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
    }) do
      it("does not grant an unrelated tool: " .. name, function()
        assert.is_false(vocabulary.is_always_allowed(name))
      end)
    end
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
    end)
  end)
end)
