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

    it("instructs the model to pass chat_file_path on nvim_ask_user_question, without any per-turn id", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find("nvim_ask_user_question", 1, true) ~= nil)
      assert.is_true(prompt_text:find("chat_file_path argument", 1, true) ~= nil)
    end)

    it("never embeds a handle_id, so the same conversation's system prompt is byte-identical across turns", function()
      local opts = { chat_file_path = "/tmp/chat-test.md" }
      local cmd1 = cli_command_builder.build("hello", opts, nil, {}, nil, 9878)
      local cmd2 = cli_command_builder.build("hello again", opts, "session-1", {}, nil, 9878)
      local idx1 = find_flag(cmd1, "--append-system-prompt")
      local idx2 = find_flag(cmd2, "--append-system-prompt")
      assert.equals(cmd1[idx1 + 1], cmd2[idx2 + 1])
      assert.is_nil(cmd1[idx1 + 1]:find("handle_id", 1, true))
    end)

    it("embeds the rpc_port and instructs the model to echo it back on every vibing-nvim MCP call", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil, 9878)
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

    it("passes --disallowedTools naming the known built-in tools", function()
      -- An empty --allowedTools alone does not reliably block tool execution (verified against
      -- the CLI directly: the model can still invoke Bash/Write with an empty allow list and no
      -- --permission-mode, or with --permission-mode dontAsk). --permission-mode plan does
      -- hard-block tool use, but was also verified to leak plan-mode meta-commentary into
      -- otherwise plain text-generation output, corrupting title/summary content — so
      -- --disallowedTools naming the known built-in tools is used as the real defense instead.
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--disallowedTools")
      assert.is_not_nil(idx)
      local disallowed = cmd[idx + 1]
      assert.is_true(disallowed:find("Bash", 1, true) ~= nil)
      assert.is_true(disallowed:find("Write", 1, true) ~= nil)
      assert.is_true(disallowed:find("Task", 1, true) ~= nil)
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

    it("omits the worktree/ask_user_question/rpc_port tool instructions from the system prompt", function()
      local cmd = cli_command_builder.build(
        "hello",
        { lightweight = true, chat_file_path = "/tmp/chat-test.md" },
        nil,
        {},
        nil,
        9878
      )
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find(".vibing/worktrees/", 1, true))
      assert.is_nil(prompt_text:find("nvim_ask_user_question", 1, true))
      assert.is_nil(prompt_text:find("Your rpc_port for this turn is", 1, true))
      assert.is_nil(prompt_text:find("Current vibing.nvim chat buffer file:", 1, true))
    end)

    it("still applies the language instruction to the system prompt", function()
      local config = { language = "ja" }
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, config, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      assert.is_true(cmd[idx + 1]:find("Japanese", 1, true) ~= nil)
    end)
  end)

  describe("--resume / --fork-session", function()
    it("adds --resume with the given session_id when session_id is provided", function()
      local cmd = cli_command_builder.build("hello", {}, "session-abc", {}, nil)
      local idx = find_flag(cmd, "--resume")
      assert.is_not_nil(idx)
      assert.equals("session-abc", cmd[idx + 1])
    end)

    it("omits --resume when session_id is nil", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "--resume"))
    end)

    it("adds --fork-session right after --resume when opts._is_fork is true", function()
      local cmd = cli_command_builder.build("hello", { _is_fork = true }, "session-abc", {}, nil)
      local resume_idx = find_flag(cmd, "--resume")
      assert.is_not_nil(resume_idx)
      assert.equals("--fork-session", cmd[resume_idx + 2])
    end)

    it("omits --fork-session when opts._is_fork is not set, even with a session_id", function()
      local cmd = cli_command_builder.build("hello", {}, "session-abc", {}, nil)
      assert.is_nil(find_flag(cmd, "--fork-session"))
    end)

    it("omits --fork-session when opts._is_fork is true but there is no session_id to resume", function()
      local cmd = cli_command_builder.build("hello", { _is_fork = true }, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "--fork-session"))
    end)

    it("sends only the short instruction prompt (not full history) when resuming a session", function()
      local cmd = cli_command_builder.build("Please summarize.", {}, "session-abc", {}, nil)
      -- The prompt is the last argument, after the `--` end-of-options marker
      assert.equals("Please summarize.", cmd[#cmd])
    end)
  end)

  describe("--setting-sources", function()
    it("defaults to user,project,local when config.agent.setting_sources is not set", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.is_not_nil(idx)
      assert.equals("user,project,local", cmd[idx + 1])
    end)

    it("uses config.agent.setting_sources when provided", function()
      local config = { agent = { setting_sources = { "project", "local" } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.is_not_nil(idx)
      assert.equals("project,local", cmd[idx + 1])
    end)

    it("falls back to the default when setting_sources is not a table", function()
      local config = { agent = { setting_sources = "project" } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.equals("user,project,local", cmd[idx + 1])
    end)

    it("falls back to the default when setting_sources is an empty table", function()
      local config = { agent = { setting_sources = {} } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.equals("user,project,local", cmd[idx + 1])
    end)

    it("falls back to the default when setting_sources contains a non-string element", function()
      local config = { agent = { setting_sources = { "project", 42 } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.equals("user,project,local", cmd[idx + 1])
    end)

    it("falls back to the default when setting_sources contains an empty string element", function()
      local config = { agent = { setting_sources = { "project", "" } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.equals("user,project,local", cmd[idx + 1])
    end)

    it("falls back to the default when setting_sources contains an unsupported source name", function()
      local config = { agent = { setting_sources = { "project", "workspace" } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      local idx = find_flag(cmd, "--setting-sources")
      assert.equals("user,project,local", cmd[idx + 1])
    end)
  end)
end)
