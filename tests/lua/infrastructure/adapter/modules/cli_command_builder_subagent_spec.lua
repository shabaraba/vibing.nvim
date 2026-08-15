local cli_command_builder = require("vibing.infrastructure.adapter.modules.cli_command_builder")

describe("cli_command_builder subagent chat", function()
  local original_exepath
  local AGENT_ID = "ab2e2379a4f9c8c52"

  before_each(function()
    cli_command_builder._reset_path_cache()
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
    cli_command_builder._reset_path_cache()
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  local function allowed_tools(cmd)
    local idx = find_flag(cmd, "--allowedTools")
    return idx and cmd[idx + 1] or ""
  end

  local function system_prompt(cmd)
    local idx = find_flag(cmd, "--append-system-prompt")
    return idx and cmd[idx + 1] or ""
  end

  describe("--allowedTools", function()
    it("adds the tools a bound chat needs to reach its agent", function()
      local cmd = cli_command_builder.build("hi", { _subagent_id = AGENT_ID, permissions_allow = { "Read" } }, nil, {})
      local allowed = allowed_tools(cmd)

      -- SendMessage is the actual continuation mechanism; it is a deferred tool, so ToolSearch has
      -- to be allowed for the model to find it at all.
      assert.is_truthy(allowed:find("SendMessage", 1, true))
      assert.is_truthy(allowed:find("ToolSearch", 1, true))
      -- Both spellings: the CLI renamed Task to Agent in v2.1.63.
      assert.is_truthy(allowed:find("Agent", 1, true))
      assert.is_truthy(allowed:find("Task", 1, true))
    end)

    it("leaves an ordinary chat's tool set alone", function()
      local allowed = allowed_tools(cli_command_builder.build("hi", { permissions_allow = { "Read" } }, nil, {}))

      assert.is_nil(allowed:find("SendMessage", 1, true))
      assert.is_nil(allowed:find("ToolSearch", 1, true))
    end)

    it("does not duplicate a tool the user already allowed", function()
      local cmd = cli_command_builder.build(
        "hi",
        { _subagent_id = AGENT_ID, permissions_allow = { "Read", "SendMessage" } },
        nil,
        {}
      )
      local _, count = allowed_tools(cmd):gsub("SendMessage", "")
      assert.equals(1, count)
    end)
  end)

  describe("system prompt", function()
    it("tells the model to relay every message to the bound agent", function()
      local prompt = system_prompt(cli_command_builder.build("hi", { _subagent_id = AGENT_ID }, nil, {}))

      assert.is_truthy(prompt:find(AGENT_ID, 1, true))
      assert.is_truthy(prompt:find("SendMessage", 1, true))
    end)

    it("says nothing about subagents in an ordinary chat", function()
      assert.is_nil(system_prompt(cli_command_builder.build("hi", {}, nil, {})):find("bound to subagent", 1, true))
    end)

    it("stays byte-identical across turns of the same buffer", function()
      -- A per-turn value here would invalidate the cached system prefix on every message (#469).
      local opts = { _subagent_id = AGENT_ID, chat_bufnr = 7 }
      local first = system_prompt(cli_command_builder.build("hi", opts, nil, {}, nil, 9878))
      local second = system_prompt(cli_command_builder.build("again", opts, "session-1", {}, nil, 9878))

      assert.equals(first, second)
    end)
  end)

  describe("--fork-session", function()
    it("is never emitted for a bound chat", function()
      -- A forked session gets a new id, and the agent's transcript lives under the parent's id —
      -- SendMessage would fail with "No transcript found for agent ID".
      local cmd = cli_command_builder.build("hi", { _subagent_id = AGENT_ID }, "session-1", {})

      assert.is_not_nil(find_flag(cmd, "--resume"))
      assert.is_nil(find_flag(cmd, "--fork-session"))
    end)
  end)
end)
