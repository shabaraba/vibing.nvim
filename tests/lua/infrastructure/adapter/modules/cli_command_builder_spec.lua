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

  describe("lightweight mode", function()
    it("passes an empty --setting-sources to skip CLAUDE.md/rules loading", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.is_not_nil(idx)
      assert.equals("", cmd[idx + 1])
    end)

    it("disables MCP servers via --strict-mcp-config and an empty --mcp-config", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local strict_idx = find_flag(cmd, "--strict-mcp-config")
      assert.is_not_nil(strict_idx)
      local mcp_config_idx = find_flag(cmd, "--mcp-config")
      assert.is_not_nil(mcp_config_idx)
      assert.equals('{"mcpServers":{}}', cmd[mcp_config_idx + 1])
    end)

    it("passes an empty --allowedTools instead of the usual pre-approved tool list", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--allowedTools")
      assert.is_not_nil(idx)
      assert.equals("", cmd[idx + 1])
    end)

    it("does not pass --settings even when a hook settings_path is provided", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, "/tmp/settings.json")
      assert.is_nil(find_flag(cmd, "--settings"))
    end)

    it("does not pass --permission-mode even when opts.permission_mode is set", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true, permission_mode = "acceptEdits" }, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "--permission-mode"))
    end)

    it("uses config.agent.utility_model, defaulting to haiku when unset", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--model")
      assert.is_not_nil(idx)
      assert.equals("haiku", cmd[idx + 1])
    end)

    it("prefers config.agent.utility_model over opts.model and config.agent.default_model", function()
      local config = { agent = { default_model = "sonnet", utility_model = "opus" } }
      local cmd = cli_command_builder.build("hello", { lightweight = true, model = "fable" }, nil, config, nil)
      local idx = find_flag(cmd, "--model")
      assert.is_not_nil(idx)
      assert.equals("opus", cmd[idx + 1])
    end)

    it("uses opts.model as usual when lightweight is not set", function()
      local cmd = cli_command_builder.build("hello", { model = "opus" }, nil, {}, nil)
      local idx = find_flag(cmd, "--model")
      assert.is_not_nil(idx)
      assert.equals("opus", cmd[idx + 1])
    end)
  end)
end)
