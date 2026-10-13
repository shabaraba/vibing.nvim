--- The two grok argvs are one request spec with conditions on it, so the thing worth pinning is
--- that neither transport leaks into the other: `grok agent stdio` takes no prompt, no session and
--- no `--permission-mode` (it does not accept one), while the one-shot `grok --single` must stay
--- byte-for-byte what it was before the resident transport existed.

local GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")

local CONFIG = { ai = { chat = { agent = "grok", model = "grok-4.7" } } }

--- @param cmd string[]
--- @param flag string
--- @return number|nil
local function index_of(cmd, flag)
  for i, arg in ipairs(cmd) do
    if arg == flag then
      return i
    end
  end
  return nil
end

--- @param cmd string[]
--- @param flag string
--- @return string|nil
local function value_after(cmd, flag)
  local i = index_of(cmd, flag)
  return i and cmd[i + 1] or nil
end

--- @param cmd string[]
--- @param prefix string
--- @return boolean
local function has_prefixed(cmd, prefix)
  for _, arg in ipairs(cmd) do
    if arg:sub(1, #prefix) == prefix then
      return true
    end
  end
  return false
end

describe("grok duplex request", function()
  local original_exepath, original_executable

  before_each(function()
    original_exepath = vim.fn.exepath
    original_executable = vim.fn.executable
    vim.fn.exepath = function(name)
      if name == "grok" then
        return "/usr/local/bin/grok"
      end
      return original_exepath(name)
    end
    -- Reported non-executable so the official-CLI sniff is skipped; grok need not be installed.
    vim.fn.executable = function(path)
      if path == "/usr/local/bin/grok" then
        return 0
      end
      return original_executable(path)
    end
    package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
    package.loaded["vibing.infrastructure.adapter.backends.grok"] = nil
    GrokCommandBuilder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    vim.fn.executable = original_executable
    package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
    package.loaded["vibing.infrastructure.adapter.backends.grok"] = nil
  end)

  --- @param opts table
  --- @param session_id string|nil
  --- @return string[]
  local function duplex(opts, session_id)
    return GrokCommandBuilder.build(
      "hi",
      vim.tbl_extend("force", { _process_model = "duplex", cwd = "/repo" }, opts or {}),
      session_id,
      CONFIG
    )
  end

  describe("the resident argv", function()
    it("opens with the agent subcommand and closes with stdio", function()
      -- clap rejects a flag placed after the subcommand, so the order is the contract, not a style.
      local cmd = duplex({})
      assert.equals("agent", cmd[2])
      assert.equals("--no-leader", cmd[3])
      assert.equals("stdio", cmd[#cmd])
    end)

    it("puts every flag before the subcommand", function()
      local cmd = duplex({ effort = "high" })
      local stdio = index_of(cmd, "stdio")
      assert.equals(#cmd, stdio)
      assert.is_true(index_of(cmd, "--model") < stdio)
      assert.is_true(index_of(cmd, "--effort") < stdio)
    end)

    it("carries the model and effort selections, which are process flags here", function()
      local cmd = duplex({ effort = "high" })
      assert.equals("grok-4.7", value_after(cmd, "--model"))
      assert.equals("high", value_after(cmd, "--effort"))
    end)

    it("carries no prompt: it travels in session/prompt", function()
      assert.is_false(has_prefixed(duplex({}), "--single="))
    end)

    it("carries no output format: the ACP wire is not the streaming-json one", function()
      assert.is_nil(index_of(duplex({}), "--output-format"))
    end)

    it("carries no --permission-mode, which `grok agent` does not accept at all", function()
      -- The gate on this transport is the project hook plus `grok_native_approval`. Emitting a flag
      -- clap rejects would make every duplex turn fail to spawn.
      for _, mode in ipairs({ "default", "acceptEdits", "plan", "bypassPermissions" }) do
        assert.is_nil(index_of(duplex({ permission_mode = mode }), "--permission-mode"))
      end
    end)

    it("carries no --cwd or --rules, neither of which `grok agent` accepts", function()
      local cmd = duplex({})
      assert.is_nil(index_of(cmd, "--cwd"))
      assert.is_nil(index_of(cmd, "--rules"))
    end)

    it("is identical with and without a session, so the pool can reuse the process", function()
      -- `duplex_stream.reuse_key` builds the argv twice, once with no session id. A `--resume` pair
      -- that appeared only on turn 2 would make the key differ by construction on every chat's
      -- second turn, restarting the process every time while looking correct.
      assert.same(duplex({}), duplex({}, "sess-1"))
      assert.is_nil(index_of(duplex({}, "sess-1"), "--resume"))
    end)
  end)

  describe("the one-shot argv is left alone", function()
    --- @param opts table
    --- @return string[]
    local function oneshot(opts)
      return GrokCommandBuilder.build("hi", vim.tbl_extend("force", { cwd = "/repo" }, opts or {}), nil, CONFIG)
    end

    it("still passes the prompt, the streaming format, the cwd and the rules", function()
      local cmd = oneshot({})
      assert.is_true(has_prefixed(cmd, "--single="))
      assert.equals("streaming-json", value_after(cmd, "--output-format"))
      assert.equals("/repo", value_after(cmd, "--cwd"))
      assert.is_not_nil(index_of(cmd, "--rules"))
    end)

    it("still passes --permission-mode, and still has no `auto` to pass", function()
      assert.equals("acceptEdits", value_after(oneshot({ permission_mode = "acceptEdits" }), "--permission-mode"))
      assert.equals("default", value_after(oneshot({ permission_mode = "auto" }), "--permission-mode"))
    end)

    it("never becomes the agent subcommand", function()
      local cmd = oneshot({})
      assert.is_nil(index_of(cmd, "agent"))
      assert.is_nil(index_of(cmd, "stdio"))
    end)
  end)

  describe("the instructions each transport carries", function()
    it("names the choice-list tool only where it can be called", function()
      -- `--rules` serves the one-shot path, which reaches no vibing-nvim MCP server: `grok --single`
      -- rejects `--plugin-dir` and the servers travel in an ACP `session/new`. Naming the tool
      -- there would name one grok cannot invoke.
      local rules_flag = GrokCommandBuilder.rules_args({ opts = { cwd = "/repo" }, config = CONFIG })
      assert.is_nil(table.concat(rules_flag, "\n"):find("nvim_ask_user_question", 1, true))

      local duplex_text = GrokCommandBuilder.rules_text({ cwd = "/repo", chat_bufnr = 7 }, CONFIG, "vibing-nvim")
      assert.is_not_nil(duplex_text:find("nvim_ask_user_question", 1, true))
    end)

    -- The same test one level in: the name comes from the bundled server's own manifest, so with
    -- `agent.plugins.self = false` there is no server and the tool must not be named at all.
    it("says nothing about the tool when the bundled server is not loaded", function()
      local text = GrokCommandBuilder.rules_text({ cwd = "/repo", chat_bufnr = 7 }, CONFIG, nil)
      assert.is_nil(text:find("nvim_ask_user_question", 1, true))
      assert.is_nil(text:find("Current vibing.nvim chat buffer number", 1, true))
    end)

    -- Taken from the manifest rather than hard-coded, so a rename there cannot leave the model
    -- told about a tool on a server that is not registered -- `codex_plugin_config`'s reason.
    it("qualifies the tool with the server's own registered name", function()
      local text = GrokCommandBuilder.rules_text({ cwd = "/repo", chat_bufnr = 7 }, CONFIG, "renamed-server")
      assert.is_not_nil(text:find("renamed-server__nvim_ask_user_question", 1, true))
    end)

    it("qualifies the tool as server__tool, without claude's mcp__ prefix", function()
      -- grok's own error text for an unqualified name says so: "Tool names must be qualified as
      -- `server__tool`". An `mcp__`-prefixed name is one grok will not resolve.
      local text = GrokCommandBuilder.rules_text({ cwd = "/repo", chat_bufnr = 7 }, CONFIG, "vibing-nvim")
      assert.is_not_nil(text:find("vibing-nvim__nvim_ask_user_question", 1, true))
      assert.is_nil(text:find("mcp__", 1, true))
    end)

    it("carries the chat buffer number the answer is routed by", function()
      local text = GrokCommandBuilder.rules_text({ cwd = "/repo", chat_bufnr = 7 }, CONFIG, "vibing-nvim")
      assert.is_not_nil(text:find("Current vibing.nvim chat buffer number: 7", 1, true))
    end)

    it("still carries the conventions the flag carries", function()
      local text = GrokCommandBuilder.rules_text({ cwd = "/repo" }, CONFIG)
      assert.is_not_nil(text:find(".vibing/worktrees/", 1, true))
    end)
  end)
end)
