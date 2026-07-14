local grok_command_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")

describe("grok_command_builder", function()
  local original_exepath
  local original_executable
  local original_system

  before_each(function()
    original_exepath = vim.fn.exepath
    original_executable = vim.fn.executable
    original_system = vim.fn.system
    vim.fn.exepath = function(name)
      if name == "grok" then
        return "/usr/local/bin/grok"
      end
      return original_exepath(name)
    end
    -- Mock PATH binary as non-executable so official-version sniff is skipped by default
    vim.fn.executable = function(path)
      if path == "/usr/local/bin/grok" then
        return 0
      end
      if path == "/opt/custom/grok" then
        return 1
      end
      return original_executable(path)
    end
    vim.fn.system = function(cmd)
      if type(cmd) == "table" and cmd[1] == "/opt/custom/grok" and cmd[2] == "--version" then
        return "grok 0.2.101 (5bc4b5dfadcf) [stable]\n"
      end
      return original_system(cmd)
    end
    package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
    grok_command_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    vim.fn.executable = original_executable
    vim.fn.system = original_system
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  local function find_prefixed(cmd, prefix)
    for _, arg in ipairs(cmd) do
      if arg:sub(1, #prefix) == prefix then
        return arg
      end
    end
    return nil
  end

  describe("prompt argument", function()
    it("passes the prompt as a single --single=<value> token, not two argv entries", function()
      local cmd = grok_command_builder.build("hello world", {}, nil, {})
      local single_arg = find_prefixed(cmd, "--single=")
      assert.is_not_nil(single_arg)
      assert.equals("--single=hello world", single_arg)
      assert.is_nil(find_flag(cmd, "-p"))
    end)

    it("keeps a hyphen-leading prompt intact inside the --single= token (clap ambiguity guard)", function()
      local cmd = grok_command_builder.build("-1 is negative, true or false?", {}, nil, {})
      local single_arg = find_prefixed(cmd, "--single=")
      assert.equals("--single=-1 is negative, true or false?", single_arg)
    end)

    it("prefixes context files only for new sessions, not resume", function()
      local cmd = grok_command_builder.build("hello", { context = { "@file:init.lua" } }, nil, {})
      local single_arg = find_prefixed(cmd, "--single=")
      assert.is_true(single_arg:find("Context file: init.lua", 1, true) ~= nil)

      local resumed_cmd =
        grok_command_builder.build("hello", { context = { "@file:init.lua" } }, "session-abc", {})
      local resumed_single_arg = find_prefixed(resumed_cmd, "--single=")
      assert.is_nil(resumed_single_arg:find("Context file:", 1, true))
    end)
  end)

  it("always requests streaming-json output", function()
    local cmd = grok_command_builder.build("hello", {}, nil, {})
    local idx = find_flag(cmd, "--output-format")
    assert.is_not_nil(idx)
    assert.equals("streaming-json", cmd[idx + 1])
  end)

  describe("--rules (system prompt additions)", function()
    it("always appends the worktree directory convention instruction", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {})
      local idx = find_flag(cmd, "--rules")
      assert.is_not_nil(idx)
      assert.is_true(cmd[idx + 1]:find(".vibing/worktrees/", 1, true) ~= nil)
    end)

    it("combines the language instruction and worktree instruction into a single flag", function()
      local config = { language = "ja" }
      local cmd = grok_command_builder.build("hello", {}, nil, config)

      local count = 0
      local rules_text = nil
      for i, arg in ipairs(cmd) do
        if arg == "--rules" then
          count = count + 1
          rules_text = cmd[i + 1]
        end
      end

      assert.equals(1, count)
      assert.is_true(rules_text:find("Japanese", 1, true) ~= nil)
      assert.is_true(rules_text:find(".vibing/worktrees/", 1, true) ~= nil)
    end)

    it("appends the current chat buffer file path when provided", function()
      local cmd = grok_command_builder.build("hello", { chat_file_path = "/tmp/chat-test.md" }, nil, {})
      local idx = find_flag(cmd, "--rules")
      assert.is_true(
        cmd[idx + 1]:find("Current vibing.nvim chat buffer file: /tmp/chat-test.md", 1, true) ~= nil
      )
    end)

    it("omits the chat buffer file line when chat_file_path is not provided", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {})
      local idx = find_flag(cmd, "--rules")
      assert.is_nil(cmd[idx + 1]:find("Current vibing.nvim chat buffer file:", 1, true))
    end)

    it("embeds the handle_id and instructs the model to echo it back on nvim_ask_user_question", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {}, "abc123_456")
      local idx = find_flag(cmd, "--rules")
      assert.is_true(cmd[idx + 1]:find('Your handle_id for this turn is "abc123_456"', 1, true) ~= nil)
      assert.is_true(cmd[idx + 1]:find("nvim_ask_user_question", 1, true) ~= nil)
    end)

    it("embeds the rpc_port and instructs the model to echo it back on every vibing-nvim MCP call", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {}, nil, 9878)
      local idx = find_flag(cmd, "--rules")
      assert.is_true(cmd[idx + 1]:find("Your rpc_port for this turn is 9878", 1, true) ~= nil)
      assert.is_true(cmd[idx + 1]:find("mcp__vibing-nvim__*", 1, true) ~= nil)
    end)
  end)

  describe("--model", function()
    it("omits --model for Claude-style model names (grok has its own defaults)", function()
      local cmd = grok_command_builder.build("hello", { model = "sonnet" }, nil, {})
      assert.is_nil(find_flag(cmd, "--model"))
    end)

    it("passes through Grok model names", function()
      local cmd = grok_command_builder.build("hello", { model = "grok-4.5" }, nil, {})
      local idx = find_flag(cmd, "--model")
      assert.is_not_nil(idx)
      assert.equals("grok-4.5", cmd[idx + 1])
    end)
  end)

  describe("--permission-mode", function()
    it("passes vibing permission modes straight through with no translation", function()
      for _, mode in ipairs({ "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto" }) do
        local cmd = grok_command_builder.build("hello", { permission_mode = mode }, nil, {})
        local idx = find_flag(cmd, "--permission-mode")
        assert.is_not_nil(idx, "missing --permission-mode for " .. mode)
        assert.equals(mode, cmd[idx + 1])
      end
    end)

    it("omits --permission-mode when not specified", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {})
      assert.is_nil(find_flag(cmd, "--permission-mode"))
    end)
  end)

  describe("session resume", function()
    it("adds --resume with the session id", function()
      local cmd = grok_command_builder.build("hello", {}, "session-abc", {})
      local idx = find_flag(cmd, "--resume")
      assert.is_not_nil(idx)
      assert.equals("session-abc", cmd[idx + 1])
    end)

    it("adds --fork-session only when resuming a forked chat", function()
      local cmd = grok_command_builder.build("hello", { _is_fork = true }, "session-abc", {})
      assert.is_not_nil(find_flag(cmd, "--fork-session"))
    end)

    it("omits --fork-session for a plain resume", function()
      local cmd = grok_command_builder.build("hello", {}, "session-abc", {})
      assert.is_nil(find_flag(cmd, "--fork-session"))
    end)

    it("omits --resume for a new session", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {})
      assert.is_nil(find_flag(cmd, "--resume"))
    end)
  end)

  describe("--cwd", function()
    it("adds --cwd when opts.cwd is set", function()
      local cmd = grok_command_builder.build("hello", { cwd = "/tmp/worktree" }, nil, {})
      local idx = find_flag(cmd, "--cwd")
      assert.is_not_nil(idx)
      assert.equals("/tmp/worktree", cmd[idx + 1])
    end)

    it("omits --cwd when not set", function()
      local cmd = grok_command_builder.build("hello", {}, nil, {})
      assert.is_nil(find_flag(cmd, "--cwd"))
    end)
  end)

  describe("binary resolution", function()
    it("uses config.grok.executable when set to an explicit path", function()
      -- Force non-executable so sniff is skipped; path is still used in argv
      local cmd = grok_command_builder.build("hello", {}, nil, {
        grok = { executable = "/opt/custom/grok" },
      })
      assert.equals("/opt/custom/grok", cmd[1])
    end)

    it("errors when the grok binary cannot be found", function()
      vim.fn.exepath = function()
        return ""
      end
      package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
      local fresh_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
      assert.has_error(function()
        fresh_builder.build("hello", {}, nil, {})
      end)
    end)
  end)
end)
