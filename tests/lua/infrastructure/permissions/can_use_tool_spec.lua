local can_use_tool = require("vibing.infrastructure.permissions.can_use_tool")

--- Build a minimal PermissionConfig for tests
---@param overrides table
---@return PermissionConfig
local function make_config(overrides)
  return vim.tbl_extend("force", {
    allowed_tools = {},
    denied_tools = {},
    asked_tools = {},
    session_allowed_tools = {},
    session_denied_tools = {},
    permission_rules = {},
    permission_mode = "default",
    mcp_enabled = false,
  }, overrides or {})
end

describe("can_use_tool", function()
  describe("backend-specific always-allowed tools", function()
    local vocabulary = require("vibing.infrastructure.adapter.modules.codex_tool_vocabulary")
    local function decision(name, overrides, input)
      return can_use_tool.can_use_tool(
        name,
        input or {},
        make_config(vim.tbl_extend("force", {
          allowed_tools = { "Read" },
          is_always_allowed = vocabulary.is_always_allowed,
        }, overrides or {}))
      ).behavior
    end

    it("only applies when the backend supplies the predicate", function()
      assert.equals("allow", decision("collaborationspawn_agent"))
      assert.equals(
        "ask",
        can_use_tool.can_use_tool(
          "collaborationspawn_agent",
          {},
          make_config({
            allowed_tools = { "Read" },
          })
        ).behavior
      )
      assert.equals("ask", decision("mcp__other__write"))
    end)

    it("keeps canonical operations under their existing permission settings", function()
      for _, name in ipairs({ "Bash", "Edit", "Write", "WebSearch", "WebFetch" }) do
        assert.equals("ask", decision(name), name)
        assert.equals("allow", decision(name, { allowed_tools = { name } }), name)
      end
      for _, name in ipairs({ "Read", "Glob", "Grep" }) do
        assert.equals("allow", decision(name), name)
        assert.equals("deny", decision(name, { denied_tools = { name } }), name)
      end
    end)

    it("respects explicit ask, deny and session deny", function()
      assert.equals("ask", decision("collaborationspawn_agent", { asked_tools = { "collaboration*" } }))
      assert.equals("deny", decision("collaborationspawn_agent", { denied_tools = { "collaboration*" } }))
      assert.equals("deny", decision("collaborationspawn_agent", { session_denied_tools = { "collaboration*" } }))
      assert.equals(
        "deny",
        decision("collaborationspawn_agent", {
          asked_tools = { "collaboration*" },
          permission_mode = "dontAsk",
        })
      )
    end)

    it("keeps command deny rules and the background-job invariant ahead of built-in allowances", function()
      assert.equals(
        "deny",
        decision("Bash", {
          permission_rules = { { tools = { "Bash" }, action = "deny", commands = { "echo" } } },
        }, { command = "echo forbidden" })
      )
      assert.equals("deny", decision("Bash", { mcp_enabled = true }, { command = "npm run dev &" }))
    end)
  end)

  describe("Neovim-owned background-job policy", function()
    local function decision(input, overrides)
      return can_use_tool.can_use_tool("Bash", input, make_config(vim.tbl_extend("force", {
        mcp_enabled = true,
        permission_mode = "bypassPermissions",
      }, overrides or {})))
    end

    it("denies the Bash tool's native background mode even under bypassPermissions", function()
      local result = decision({ command = "npm run dev", run_in_background = true })
      assert.equals("deny", result.behavior)
      assert.is_truthy(result.message:find("nvim_job_start", 1, true))
    end)

    for _, command in ipairs({
      "npm run dev &",
      "nohup npm run dev",
      "setsid npm run dev",
      "sleep 1&",
      "sudo -u www-data setsid npm run dev",
      "sudo --preserve-env=PATH env FOO=bar nohup npm run dev",
    }) do
      it("denies detached shell command: " .. command, function()
        assert.equals("deny", decision({ command = command }).behavior)
      end)
    end

    local foreground_commands = { "npm test", "echo a && echo b", "echo x 2>&1", "printf 'a & b'", "printf nohup" }
    for _, command in ipairs(foreground_commands) do
      it("allows foreground shell command: " .. command, function()
        assert.equals("allow", decision({ command = command }).behavior)
      end)
    end

    it("does not require an unavailable MCP replacement", function()
      assert.equals("allow", decision({ command = "sleep 1 &" }, { mcp_enabled = false }).behavior)
    end)
  end)

  describe("ALWAYS_ALLOWED_TOOLS (UT-PERM-010)", function()
    local always_allowed = {
      "Read",
      "Glob",
      "Grep",
      "Skill",
      "StructuredOutput",
      "mcp__codex_apps__search",
      "mcp__cua_repl__js",
    }

    for _, tool in ipairs(always_allowed) do
      it(string.format("should allow %s even when permissions_allow is empty", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          allowed_tools = {},
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should allow %s even when permissions_allow does not include it", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          allowed_tools = { "Edit", "Write" },
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should deny %s when explicitly in deny list", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          denied_tools = { tool },
        }))
        assert.equals("deny", result.behavior)
      end)

      it(string.format("should ask for %s when in ask list", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          asked_tools = { tool },
        }))
        assert.equals("ask", result.behavior)
      end)

      it(string.format("should deny %s when in both deny and ask lists (deny wins)", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          denied_tools = { tool },
          asked_tools = { tool },
        }))
        assert.equals("deny", result.behavior)
      end)
    end
  end)

  describe("INTERNAL_TOOLS are allowed even over deny (UT-PERM-012)", function()
    -- ハーネスの制御に必須なツール。ALWAYS_ALLOWED_TOOLSと違い、deny/askすら通さず常に許可。
    -- 名前は `Tools.INTERNAL_TOOLS` から引かずに直接書く。あちらを回すとこのテストは
    -- 「あちらに載っているものは許可される」しか言わなくなり、載せ忘れを検出できない。
    local internal = {
      "ToolSearch",
      "TodoWrite",
      "ReportFindings",
      "ScheduleWakeup",
      "SendMessage",
      "ListAgents",
    }

    for _, tool in ipairs(internal) do
      it(string.format("should allow %s even when in the deny list", tool), function()
        local result = can_use_tool.can_use_tool(tool, {}, make_config({
          denied_tools = { tool },
        }))
        assert.equals("allow", result.behavior)
      end)
    end
  end)

  describe("non-always-allowed tools are still gated by allow list (UT-PERM-011)", function()
    it("should ask for Bash when not in allow list and mode is default", function()
      local result = can_use_tool.can_use_tool("Bash", {}, make_config({
        allowed_tools = { "Read", "Edit" },
        permission_mode = "default",
      }))
      assert.equals("ask", result.behavior)
    end)

    it("should allow Edit when in allow list", function()
      local result = can_use_tool.can_use_tool("Edit", {}, make_config({
        allowed_tools = { "Edit" },
      }))
      assert.equals("allow", result.behavior)
    end)
  end)

  describe("vibing-nvim MCP tools (regardless of registration namespace)", function()
    local tool_names = {
      -- Registered as a plain user-level MCP server
      "mcp__vibing-nvim__nvim_get_buffer",
      -- Registered as a Claude Code plugin (marketplace "vibing", plugin "vibing-nvim")
      "mcp__plugin_vibing_vibing-nvim__nvim_get_buffer",
    }

    for _, tool_name in ipairs(tool_names) do
      it(string.format("should allow %s without permissions_allow when mcp_enabled", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          allowed_tools = {},
          permission_mode = "default",
          mcp_enabled = true,
        }))
        assert.equals("allow", result.behavior)
      end)

      it(string.format("should deny %s when mcp_enabled is false", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          mcp_enabled = false,
        }))
        assert.equals("deny", result.behavior)
      end)

      it(string.format("should still deny %s when explicitly in deny list", tool_name), function()
        local result = can_use_tool.can_use_tool(tool_name, {}, make_config({
          denied_tools = { tool_name },
          mcp_enabled = true,
        }))
        assert.equals("deny", result.behavior)
      end)
    end

    it("does not match unrelated MCP tools", function()
      local result = can_use_tool.can_use_tool("mcp__chrome-devtools__navigate_page", {}, make_config({
        allowed_tools = { "Read", "Edit" },
        permission_mode = "default",
        mcp_enabled = true,
      }))
      assert.equals("ask", result.behavior)
    end)
  end)

  describe("MCP server labels spelled with `-` or `_` by different backends", function()
    -- Codex normalizes an MCP server label's `-` to `_` before composing the tool name, so
    -- `chrome-devtools` reaches the hook as `mcp__chrome_devtools__*` while claude sends it
    -- verbatim. One allow entry has to cover both, or the rule silently misses on one backend.
    local function decision(tool_name, overrides)
      return can_use_tool.can_use_tool(tool_name, {}, make_config(vim.tbl_extend("force", {
        permission_mode = "default",
        mcp_enabled = true,
      }, overrides or {}))).behavior
    end

    it("matches a hyphenated allow pattern against either spelling", function()
      local allowed = { allowed_tools = { "mcp__chrome-devtools__*" } }
      assert.equals("allow", decision("mcp__chrome-devtools__take_snapshot", allowed))
      assert.equals("allow", decision("mcp__chrome_devtools__take_snapshot", allowed))
    end)

    it("closes the same gap on the deny side, where a miss falls open", function()
      local denied = { denied_tools = { "mcp__chrome-devtools__*" } }
      assert.equals("deny", decision("mcp__chrome-devtools__take_snapshot", denied))
      assert.equals("deny", decision("mcp__chrome_devtools__take_snapshot", denied))
    end)

    it("does not widen the match beyond the separator", function()
      -- Folding `-` onto `_` must not turn the pattern into a looser prefix: a different server
      -- whose name merely starts the same way stays unmatched.
      assert.equals("ask", decision("mcp__chrome-devtools-beta__take_snapshot", {
        allowed_tools = { "mcp__chrome-devtools__*" },
      }))
    end)
  end)

  describe("is_vibing_nvim_mcp_tool", function()
    it("matches a specific tool regardless of registration namespace", function()
      assert.is_true(
        can_use_tool.is_vibing_nvim_mcp_tool(
          "mcp__plugin_vibing_vibing-nvim__nvim_ask_user_question",
          "nvim_ask_user_question"
        )
      )
      assert.is_true(
        can_use_tool.is_vibing_nvim_mcp_tool("mcp__vibing-nvim__nvim_ask_user_question", "nvim_ask_user_question")
      )
    end)

    it("does not match a different vibing-nvim tool", function()
      assert.is_false(
        can_use_tool.is_vibing_nvim_mcp_tool(
          "mcp__plugin_vibing_vibing-nvim__nvim_get_buffer",
          "nvim_ask_user_question"
        )
      )
    end)

    it("does not match native AskUserQuestion", function()
      assert.is_false(can_use_tool.is_vibing_nvim_mcp_tool("AskUserQuestion", "nvim_ask_user_question"))
    end)

    it("matches grok's unprefixed server__tool form", function()
      -- grok 1.0.50 qualifies an MCP tool as `server__tool` with no `mcp__` prefix, so vibing's
      -- own server arrives with nothing at all before its name.
      assert.is_true(can_use_tool.is_vibing_nvim_mcp_tool("vibing-nvim__nvim_get_info"))
      assert.is_true(
        can_use_tool.is_vibing_nvim_mcp_tool("vibing-nvim__nvim_ask_user_question", "nvim_ask_user_question")
      )
    end)

    it("does not match a server whose name merely ends with vibing-nvim", function()
      -- Matching here would grant an unrelated server the CLI-gate bypass. grok's form has no
      -- leading separator, so the rejection rests on the server name being anchored -- either at
      -- the start of the tool name or right after a `_` -- rather than on requiring a separator.
      assert.is_false(can_use_tool.is_vibing_nvim_mcp_tool("mcp__my-vibing-nvim__nvim_get_buffer"))
      assert.is_false(can_use_tool.is_vibing_nvim_mcp_tool("my-vibing-nvim__nvim_get_buffer"))
      assert.is_false(
        can_use_tool.is_vibing_nvim_mcp_tool("mcp__my-vibing-nvim__nvim_ask_user_question", "nvim_ask_user_question")
      )
      assert.is_false(
        can_use_tool.is_vibing_nvim_mcp_tool("my-vibing-nvim__nvim_ask_user_question", "nvim_ask_user_question")
      )
    end)

    it("does not match a non-nvim_ tool on the vibing-nvim server", function()
      assert.is_false(can_use_tool.is_vibing_nvim_mcp_tool("mcp__vibing-nvim__something_else"))
    end)
  end)

  describe("an exclusive tool set", function()
    local function decision(tool, overrides, input)
      return can_use_tool.can_use_tool(
        tool,
        input or {},
        make_config(vim.tbl_extend("force", {
          exclusive_tools = { "Grep", "mcp__vibing-nvim__nvim_session_read" },
          mcp_enabled = true,
        }, overrides or {}))
      ).behavior
    end

    it("allows what it names", function()
      assert.equals("allow", decision("Grep"))
      assert.equals("allow", decision("mcp__vibing-nvim__nvim_session_read"))
    end)

    it("denies what is otherwise always allowed", function()
      assert.equals("deny", decision("Read"))
      assert.equals("deny", decision("Agent"))
      assert.equals("deny", decision("mcp__vibing-nvim__nvim_execute"))
    end)

    it("holds even under bypassPermissions", function()
      assert.equals("deny", decision("Bash", { permission_mode = "bypassPermissions" }, { command = "ls" }))
    end)

    it("does not lift a deny rule on a tool it names", function()
      assert.equals("deny", decision("Grep", { denied_tools = { "Grep" } }))
    end)

    it("is absent from an ordinary chat", function()
      assert.equals("allow", can_use_tool.can_use_tool("Read", {}, make_config({})).behavior)
    end)
  end)

  describe("a Bash prefix in the allow list", function()
    local function decision(command, overrides)
      return can_use_tool.can_use_tool(
        "Bash",
        { command = command },
        make_config(vim.tbl_extend("force", {
          allowed_tools = { "Bash(gh pr view:*)", "Bash(rg:*)" },
        }, overrides or {}))
      ).behavior
    end

    it("matches a multi-word prefix word for word", function()
      assert.equals("allow", decision("gh pr view 876"))
      assert.equals("allow", decision("gh  pr   view"))
      assert.equals("ask", decision("gh pr merge 876"))
      assert.equals("ask", decision("gh pr viewer"))
    end)

    it("still matches a single-word prefix only as a whole word", function()
      assert.equals("allow", decision("rg -c foo"))
      assert.equals("ask", decision("rgx foo"))
    end)

    it("counts as pre-approved in dontAsk mode", function()
      assert.equals("allow", decision("gh pr view 876", { permission_mode = "dontAsk" }))
      assert.equals("allow", decision("rg -c foo", { permission_mode = "dontAsk" }))
      assert.equals("deny", decision("gh pr merge 876", { permission_mode = "dontAsk" }))
    end)

    it("is still taken back by the ask list in dontAsk mode", function()
      assert.equals(
        "deny",
        decision("rg -c foo", { permission_mode = "dontAsk", asked_tools = { "Bash(rg:*)" } })
      )
    end)
  end)

  describe("shell commands through nvim_execute and nvim_job_start", function()
    local tools = require("vibing.core.constants.tools")
    local destructive = require("vibing.core.constants.destructive_commands")
    local EXECUTE = "mcp__vibing-nvim__nvim_execute"
    local JOB = "mcp__vibing-nvim__nvim_job_start"

    local function decide(tool, input, overrides)
      return can_use_tool.can_use_tool(tool, input, make_config(vim.tbl_extend("force", {
        allowed_tools = tools.DEFAULT_ALLOWED_TOOLS,
        denied_tools = { "Bash" },
        permission_mode = "acceptEdits",
        mcp_enabled = true,
        permission_rules = destructive.DEFAULT_DENY_RULES,
      }, overrides or {})))
    end

    local function job(argv)
      return { command = argv, from_bufnr = 1 }
    end

    it("denies :! and nvim_job_start under the default Bash denial", function()
      local ex = decide(EXECUTE, { command = "!ls" })
      assert.equals("deny", ex.behavior)
      assert.is_truthy(ex.message:find("Bash", 1, true))
      assert.is_truthy(ex.message:find("ls", 1, true))

      local started = decide(JOB, job({ "npm", "test" }))
      assert.equals("deny", started.behavior)
      assert.is_truthy(started.message:find("nvim_job_start", 1, true))
      assert.is_truthy(started.message:find("Bash", 1, true))
    end)

    it("denies the same commands under the plugin and grok tool names", function()
      assert.equals(
        "deny",
        decide("mcp__plugin_vibing-nvim_vibing-nvim__nvim_execute", { command = ":!ls" }).behavior
      )
      assert.equals("deny", decide("vibing-nvim__nvim_job_start", job({ "ls" })).behavior)
    end)

    it("still allows ordinary Ex commands and the other job tools", function()
      for _, command in ipairs({
        "write",
        "w! file.txt",
        "edit file.txt",
        "split",
        "lua print(1)",
        "vimgrep /foo/ %",
        "normal! j",
        ":%s/!foo/bar/",
      }) do
        assert.equals("allow", decide(EXECUTE, { command = command }).behavior, command)
      end
      assert.equals("allow", decide("mcp__vibing-nvim__nvim_job_status", { job_id = "job-1" }).behavior)
    end)

    it("asks when Bash would ask", function()
      local ask = { denied_tools = {}, permission_mode = "default" }
      assert.equals("ask", decide(EXECUTE, { command = "!ls" }, ask).behavior)
      assert.equals("ask", decide(JOB, job({ "npm", "test" }), ask).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "write" }, ask).behavior)
    end)

    it("denies instead of asking in dontAsk mode", function()
      local quiet = { denied_tools = {}, permission_mode = "dontAsk" }
      assert.equals("deny", decide(EXECUTE, { command = "!ls" }, quiet).behavior)
      assert.equals("deny", decide(JOB, job({ "curl", "https://example.com" }), quiet).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "edit file.txt" }, quiet).behavior)
    end)

    it("recognizes the other Ex shell forms", function()
      local ask = { denied_tools = {}, permission_mode = "default" }
      for _, command in ipairs({
        ":!ls -la",
        "silent !ls",
        ":%!sort",
        "1,$!sort -u",
        "read !ls",
        "0r !ls",
        "write !wc -l",
        "w! !cmd",
        "write ++ff=unix !wc",
        "terminal npm run dev",
        "3tab terminal ls",
        "debug !ls",
        "write | !ls",
        "execute '!ls'",
        "lua vim.fn.system('ls')",
        "lua vim.fn.system({'ls'})",
        "call system('ls')",
        "call systemlist('ls')",
        "lua os.execute('ls')",
        "lua io.popen('ls')",
        "lua vim.system({'ls'})",
        "lua vim.uv.spawn('ls', {})",
        "lua vim.cmd('!ls')",
        "echo system('ls')",
        "let x = system('ls')",
        "make test",
        "grep foo",
        "lgrep foo",
        "py3 os.system('ls')",
      }) do
        assert.equals("ask", decide(EXECUTE, { command = command }, ask).behavior, command)
      end
    end)

    it("applies a Bash allow prefix to the extracted command", function()
      local allowed = {
        denied_tools = {},
        permission_mode = "dontAsk",
        allowed_tools = { "Bash(npm:*)" },
      }
      assert.equals("allow", decide(JOB, job({ "npm", "test" }), allowed).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "!npm test" }, allowed).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "terminal npm run dev" }, allowed).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "lua vim.cmd('!npm test')" }, allowed).behavior)
      assert.equals("deny", decide(JOB, job({ "curl", "https://example.com" }), allowed).behavior)
      assert.equals("deny", decide(EXECUTE, { command = "!curl https://example.com" }, allowed).behavior)
    end)

    it("keeps destructive Bash rules in front of auto mode and a session grant", function()
      local session = { EXECUTE .. ":once" }
      local config_overrides = {
        denied_tools = {},
        permission_mode = "auto",
        session_allowed_tools = session,
      }
      local removed = decide(JOB, job({ "rm", "-rf", "/" }), config_overrides)
      assert.equals("deny", removed.behavior)
      assert.is_truthy(removed.message:find("Recursive deletion", 1, true))

      assert.equals("deny", decide(EXECUTE, { command = "!sudo ls" }, config_overrides).behavior)
      assert.equals(
        "deny",
        decide(EXECUTE, { command = "lua vim.fn.system('rm -rf /')" }, config_overrides).behavior
      )
      assert.equals(
        "deny",
        decide(EXECUTE, { command = "lua vim.fn.system({'rm', '-rf', '/'})" }, config_overrides).behavior
      )
      -- The destructive call never reached the session grant, so the :once entry is still there
      -- for a later command that is not denied.
      assert.same({ EXECUTE .. ":once" }, session)

      assert.equals("allow", decide(JOB, job({ "npm", "test" }), config_overrides).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "!ls" }, config_overrides).behavior)
      assert.same({}, session)
    end)

    it("does not treat an argv metacharacter as shell backgrounding", function()
      local bypass = { permission_mode = "bypassPermissions" }
      assert.equals("allow", decide(JOB, job({ "echo", "a & b" }), bypass).behavior)
      assert.equals("allow", decide(JOB, job({ "npm", "run", "dev" }), bypass).behavior)
      assert.equals("allow", decide(EXECUTE, { command = "!ls" }, bypass).behavior)

      local ampersand = decide(EXECUTE, { command = "!sleep 1 &" }, bypass)
      assert.equals("deny", ampersand.behavior)
      assert.is_truthy(ampersand.message:find("nvim_job_start", 1, true))

      local inner = decide(JOB, job({ "bash", "-c", "sleep 1 &" }), bypass)
      assert.equals("deny", inner.behavior)
      assert.is_truthy(inner.message:find("detaches", 1, true))
      assert.equals(
        "deny",
        decide(JOB, job({ "sudo", "-u", "nobody", "bash", "-c", "sleep 1 &" }), bypass).behavior
      )

      assert.equals("deny", decide(JOB, job({ "nohup", "npm", "run", "dev" }), bypass).behavior)
    end)

    it("still denies a shell tool that the exclusive set did not name", function()
      assert.equals(
        "deny",
        decide(JOB, job({ "npm", "test" }), {
          denied_tools = {},
          allowed_tools = { "Bash" },
          permission_mode = "bypassPermissions",
          exclusive_tools = { "Grep" },
        }).behavior
      )
    end)
  end)
end)
