local cli_command_builder = require("vibing.infrastructure.adapter.modules.cli_command_builder")

describe("cli_command_builder", function()
  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function(name)
      if name == "claude" then
        return "/usr/local/bin/claude"
      end
      return original_exepath(name)
    end
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  describe("system prompt", function()
    it("always appends the worktree directory convention instruction", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find(".vibing/worktrees/", 1, true) ~= nil)
    end)

    it("combines the language instruction and worktree instruction into a single flag", function()
      local config = { language = "ja" }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)

      local count = 0
      local prompt_text = nil
      for i, arg in ipairs(cmd) do
        if arg == "--append-system-prompt" then
          count = count + 1
          prompt_text = cmd[i + 1]
        end
      end

      assert.equals(1, count)
      assert.is_true(prompt_text:find("Japanese", 1, true) ~= nil)
      assert.is_true(prompt_text:find(".vibing/worktrees/", 1, true) ~= nil)
    end)

    it("appends the current chat buffer file path when provided", function()
      local cmd = cli_command_builder.build("hello", { chat_file_path = "/tmp/chat-test.md" }, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(
        prompt_text:find("Current vibing.nvim chat buffer file: /tmp/chat-test.md", 1, true) ~= nil
      )
    end)

    it("omits the chat buffer file line when chat_file_path is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Current vibing.nvim chat buffer file:", 1, true))
    end)

    it("embeds the handle_id and instructs the model to echo it back on nvim_ask_user_question", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil, "abc123_456")
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find('Your handle_id for this turn is "abc123_456"', 1, true) ~= nil)
      assert.is_true(prompt_text:find("nvim_ask_user_question", 1, true) ~= nil)
    end)

    it("omits the handle_id line when handle_id is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Your handle_id for this turn is", 1, true))
    end)

    it("embeds the rpc_port and instructs the model to echo it back on every vibing-nvim MCP call", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil, nil, 9878)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find("Your rpc_port for this turn is 9878", 1, true) ~= nil)
      assert.is_true(prompt_text:find("mcp__vibing-nvim__*", 1, true) ~= nil)
    end)

    it("omits the rpc_port line when rpc_port is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Your rpc_port for this turn is", 1, true))
    end)
  end)

  describe("--allowedTools", function()
    it("always pre-approves both vibing-nvim MCP registration styles (plain and plugin-scoped)", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--allowedTools")
      assert.is_not_nil(idx)
      local allowed = cmd[idx + 1]
      assert.is_true(allowed:find("mcp__vibing-nvim__*", 1, true) ~= nil)
      assert.is_true(allowed:find("mcp__plugin_vibing-nvim_vibing-nvim__*", 1, true) ~= nil)
    end)
  end)
end)
