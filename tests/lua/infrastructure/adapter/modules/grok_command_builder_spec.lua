local grok_command_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
local helper = require("tests.helpers.adapter_stream")

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

  local function value_after(cmd, flag)
    local index = find_flag(cmd, flag)
    return index and cmd[index + 1] or nil
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

    it("names no MCP tool, because Grok cannot reach the vibing-nvim MCP server", function()
      -- Grok registers no MCP server and no chat_bufnr, so an instruction to call
      -- nvim_ask_user_question would name a tool it has no way to invoke. Same position as codex.
      local cmd = grok_command_builder.build("hello", { chat_bufnr = 12 }, nil, {}, "abc123_456", 9878)
      local rules_text = cmd[find_flag(cmd, "--rules") + 1]

      assert.is_nil(rules_text:find("nvim_ask_user_question", 1, true))
      assert.is_nil(rules_text:find("mcp__vibing%-nvim__"))
      assert.is_nil(rules_text:find("Current vibing.nvim chat buffer", 1, true))
    end)

    it("embeds no handle_id, so the rules stay byte-identical across turns", function()
      -- A per-turn value here would invalidate the cached prompt prefix on every message (#469).
      local first = grok_command_builder.build("hello", {}, nil, {}, "handle-1", 9878)
      local second = grok_command_builder.build("again", {}, "session-1", {}, "handle-2", 9878)

      local a = first[find_flag(first, "--rules") + 1]
      local b = second[find_flag(second, "--rules") + 1]
      assert.equals(a, b)
      assert.is_nil(a:find("handle_id", 1, true))
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
    it("passes vibing permission modes straight through when Grok supports them natively", function()
      for _, mode in ipairs({ "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk" }) do
        local cmd = grok_command_builder.build("hello", { permission_mode = mode }, nil, {})
        local idx = find_flag(cmd, "--permission-mode")
        assert.is_not_nil(idx, "missing --permission-mode for " .. mode)
        assert.equals(mode, cmd[idx + 1])
      end
    end)

    it("translates 'auto' to 'default' since Grok has no background-classifier equivalent", function()
      local cmd = grok_command_builder.build("hello", { permission_mode = "auto" }, nil, {})
      local idx = find_flag(cmd, "--permission-mode")
      assert.is_not_nil(idx)
      assert.equals("default", cmd[idx + 1])
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

    it("re-resolves a cached path once the binary has moved", function()
      -- #593, for grok's own cache: the shared binary_resolver the other three backends use is not
      -- this one, so the same "hands back a path that is gone, and vim.system raises a raw ENOENT"
      -- bug lived here separately. Real files, because the check is an fs_stat.
      local moved = helper.fake_binary("grok-moved")
      local replacement = helper.fake_binary("grok-replacement")
      vim.fn.exepath = function()
        return moved
      end

      package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
      local fresh_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
      assert.equals(moved, fresh_builder.build("hello", {}, nil, {})[1])

      os.remove(moved)
      vim.fn.exepath = function()
        return replacement
      end
      assert.equals(replacement, fresh_builder.build("hello", {}, nil, {})[1], "kept the stale path")
    end)

    it("re-validates a relative path, which is a location and not a PATH lookup", function()
      -- `./bin/grok` is not a bare command name: `vim.fn.executable` resolves it against Neovim's
      -- cwd, and so does fs_stat. Skipping the check for everything that does not start with "/"
      -- left exactly this shape carrying #593 -- the cache would hand the path back after it was
      -- gone, and vim.system would raise a raw ENOENT on it.
      local relative = "./vibing-593-not-here/grok"
      assert.is_nil(vim.uv.fs_stat(relative), "the fixture path must not exist")

      local installed = true
      vim.fn.executable = function(path)
        return (path == relative and installed) and 1 or 0
      end
      vim.fn.system = function()
        return "grok 0.2.101 (5bc4b5dfadcf) [stable]\n"
      end

      package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
      local fresh_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
      local config = { grok = { executable = relative } }
      assert.equals(relative, fresh_builder.build("hello", {}, nil, config)[1])

      -- Gone. The cached path must not survive it: the user gets the actionable "not found at
      -- configured path" error instead of an ENOENT out of the spawn.
      installed = false
      assert.has_error(function()
        fresh_builder.build("hello again", {}, nil, config)
      end)
    end)

    it("still caches a bare command name, which no fs_stat can confirm", function()
      -- config.grok.executable takes a name off PATH as well as a path, and fs_stat would resolve
      -- that against Neovim's own cwd and answer nil forever. Losing the cache is not just a
      -- lookup: the fallthrough re-runs the officialness sniff, blocking the main loop on a
      -- `grok --version` subprocess on every single send.
      local sniffs = 0
      vim.fn.executable = function(path)
        return path == "grok" and 1 or 0
      end
      vim.fn.system = function()
        sniffs = sniffs + 1
        return "grok 0.2.101 (5bc4b5dfadcf) [stable]\n"
      end

      package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
      local fresh_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
      local config = { grok = { executable = "grok" } }

      fresh_builder.build("hello", {}, nil, config)
      fresh_builder.build("hello again", {}, nil, config)

      assert.equals(1, sniffs, "the sniff ran " .. sniffs .. " times: the cache is defeated")
    end)

    it("keeps rejecting an unofficial binary on every call, not just the first", function()
      -- The path used to be cached before it was verified, so a second build() hit the cache,
      -- skipped the check, and handed back the unofficial binary with no error at all.
      vim.fn.system = function(cmd)
        if type(cmd) == "table" and cmd[1] == "/opt/custom/grok" then
          return "grok-dev, a community CLI\n"
        end
        return original_system(cmd)
      end
      package.loaded["vibing.infrastructure.adapter.modules.grok_command_builder"] = nil
      local fresh_builder = require("vibing.infrastructure.adapter.modules.grok_command_builder")
      local config = { grok = { executable = "/opt/custom/grok" } }

      assert.has_error(function()
        fresh_builder.build("hello", {}, nil, config)
      end)
      assert.has_error(function()
        fresh_builder.build("hello again", {}, nil, config)
      end)
    end)
  end)

  describe("lightweight mode", function()
    it("allows only todo_write, the one tool with no file, shell or network reach", function()
      -- Grok fails open on an allowlist it cannot map: `--tools ""` is ignored and an unknown
      -- name logs "keeping full grok toolset". So this must name a real tool, which is the whole
      -- reason it cannot copy copilot's sentinel.
      local cmd = grok_command_builder.build("hi", { lightweight = true }, nil, {})
      assert.equals("todo_write", value_after(cmd, "--tools"))
    end)

    it("denies the MCP tools the allowlist cannot reach", function()
      -- `--tools` filters built-ins only; MCP tools are added on top regardless, and grok has no
      -- per-run way to turn those servers off. Denying execution is all that is left.
      local cmd = grok_command_builder.build("hi", { lightweight = true }, nil, {})
      assert.equals("MCPTool(*)", value_after(cmd, "--deny"))
    end)

    it("never waits on an approval prompt no hook is registered to answer", function()
      local cmd = grok_command_builder.build("hi", { lightweight = true }, nil, {})
      assert.equals("dontAsk", value_after(cmd, "--permission-mode"))
    end)

    it("does not inherit the chat's permission mode, bypassPermissions included", function()
      -- The user put the chat in that mode; a title generated behind their back is not the call
      -- they made, so the utility call does not inherit it.
      local cmd = grok_command_builder.build(
        "hi",
        { lightweight = true, permission_mode = "bypassPermissions" },
        nil,
        {}
      )
      assert.equals("dontAsk", value_after(cmd, "--permission-mode"))
      assert.equals("todo_write", value_after(cmd, "--tools"))
    end)

    it("still restricts a resumed session, which /summarize always is", function()
      local cmd = grok_command_builder.build("hi", { lightweight = true }, "sess-1", {})
      assert.equals("todo_write", value_after(cmd, "--tools"))
    end)

    it("drops the worktree convention it has no tool to act on", function()
      local cmd = grok_command_builder.build("hi", { lightweight = true }, nil, {})
      assert.is_nil(find_flag(cmd, "--rules"))
    end)

    it("keeps a configured language instruction in --rules", function()
      local cmd = grok_command_builder.build("hi", { lightweight = true, language = "ja" }, nil, {})
      local rules = value_after(cmd, "--rules")
      assert.is_not_nil(rules)
      assert.is_nil(rules:find("worktree", 1, true))
      assert.is_not_nil(rules:find("Japanese", 1, true))
    end)

    it("leaves an ordinary call unrestricted", function()
      local cmd = grok_command_builder.build("hi", {}, nil, {})
      assert.is_nil(find_flag(cmd, "--tools"))
      assert.is_nil(find_flag(cmd, "--deny"))
      assert.is_not_nil(find_flag(cmd, "--rules"))
    end)

    it("uses utility_model rather than default_model", function()
      local config = { agent = { default_model = "grok-4", utility_model = "grok-3-mini" } }
      local cmd = grok_command_builder.build("hi", { lightweight = true }, nil, config)
      assert.equals("grok-3-mini", value_after(cmd, "--model"))
    end)
  end)
end)
