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

    it("tells the model to open, jump and highlight rather than describe where code is", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]
      assert.is_true(prompt_text:find("nvim_highlight_range", 1, true) ~= nil)
      assert.is_true(prompt_text:find("nvim_win_open_file", 1, true) ~= nil)
      assert.is_true(prompt_text:find("nvim_set_cursor", 1, true) ~= nil)
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

    it("appends the current chat buffer number when provided", function()
      local cmd = cli_command_builder.build("hello", { chat_bufnr = 12 }, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find("Current vibing.nvim chat buffer number: 12", 1, true) ~= nil)
    end)

    it("omits the chat buffer line when chat_bufnr is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Current vibing.nvim chat buffer number:", 1, true))
    end)

    it("keeps the system prompt byte-identical when only the chat file path changes", function()
      local before = cli_command_builder.build("hello", { chat_bufnr = 12, chat_file_path = "/tmp/a.md" }, nil, {}, nil)
      local after = cli_command_builder.build(
        "hello",
        { chat_bufnr = 12, chat_file_path = "/tmp/renamed-by-set-file-title.md" },
        nil,
        {},
        nil
      )

      local before_idx = find_flag(before, "--append-system-prompt")
      local after_idx = find_flag(after, "--append-system-prompt")
      assert.equals(before[before_idx + 1], after[after_idx + 1])
    end)

    it("instructs the model to pass chat_bufnr on nvim_ask_user_question, without any per-turn id", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find("nvim_ask_user_question", 1, true) ~= nil)
      assert.is_true(prompt_text:find("chat_bufnr argument", 1, true) ~= nil)
    end)

    it("never embeds a handle_id, so the same conversation's system prompt is byte-identical across turns", function()
      local opts = { chat_bufnr = 12 }
      local cmd1 = cli_command_builder.build("hello", opts, nil, {}, nil, 9878)
      local cmd2 = cli_command_builder.build("hello again", opts, "session-1", {}, nil, 9878)
      local idx1 = find_flag(cmd1, "--append-system-prompt")
      local idx2 = find_flag(cmd2, "--append-system-prompt")
      assert.equals(cmd1[idx1 + 1], cmd2[idx2 + 1])
      assert.is_nil(cmd1[idx1 + 1]:find("handle_id", 1, true))
    end)

    it("names both MCP registration styles, so the model does not cite a tool that is not there", function()
      -- Installed as a Claude Code plugin the prefix is mcp__plugin_<marketplace>_vibing-nvim__,
      -- not mcp__vibing-nvim__. Naming only the latter made the model claim tools it could not call.
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]
      assert.is_true(prompt_text:find("mcp__vibing%-nvim__<tool>") ~= nil)
      assert.is_true(prompt_text:find("mcp__plugin_<marketplace>_vibing%-nvim__<tool>") ~= nil)
    end)

    it("embeds the rpc_port and instructs the model to echo it back on every vibing-nvim MCP call", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil, 9878)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find("Your rpc_port for this turn is 9878", 1, true) ~= nil)
      assert.is_true(prompt_text:find("mcp__vibing-nvim__", 1, true) ~= nil)
      assert.is_true(prompt_text:find("mcp__plugin_<marketplace>_vibing-nvim__", 1, true) ~= nil)
    end)

    it("omits the rpc_port line when rpc_port is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Your rpc_port for this turn is", 1, true))
    end)
  end)

  describe("project-local system prompt (.vibing/system-prompt.md)", function()
    local project_root
    local original_getcwd

    local function write_project_prompt(lines)
      vim.fn.mkdir(project_root .. "/.vibing", "p")
      vim.fn.writefile(lines, project_root .. "/.vibing/system-prompt.md")
    end

    before_each(function()
      project_root = vim.fn.tempname()
      vim.fn.mkdir(project_root, "p")
      original_getcwd = vim.fn.getcwd
      vim.fn.getcwd = function()
        return project_root
      end
    end)

    after_each(function()
      vim.fn.getcwd = original_getcwd
      vim.fn.delete(project_root, "rf")
    end)

    it("appends the file contents to --append-system-prompt", function()
      write_project_prompt({ "Prefer tabs over spaces.", "Never touch generated/." })

      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

      assert.is_true(prompt_text:find("Prefer tabs over spaces.", 1, true) ~= nil)
      assert.is_true(prompt_text:find("Never touch generated/.", 1, true) ~= nil)
    end)

    it("adds nothing when the file is missing", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local baseline = cmd[find_flag(cmd, "--append-system-prompt") + 1]

      write_project_prompt({ "" })
      local cmd2 = cli_command_builder.build("hello", {}, nil, {}, nil)
      local with_empty_file = cmd2[find_flag(cmd2, "--append-system-prompt") + 1]

      -- An empty (freshly created) file must be indistinguishable from no file at all
      assert.equals(baseline, with_empty_file)
    end)

    it("adds nothing when the file is whitespace-only", function()
      write_project_prompt({ "   ", "", "\t" })

      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

      assert.is_nil(prompt_text:find("\t", 1, true))
    end)

    it("stays byte-identical across turns while the file is unchanged", function()
      write_project_prompt({ "Project rule: always run the linter." })

      local opts = { chat_bufnr = 12 }
      local cmd1 = cli_command_builder.build("hello", opts, nil, {}, nil, 9878)
      local cmd2 = cli_command_builder.build("hello again", opts, "session-1", {}, nil, 9878)

      assert.equals(cmd1[find_flag(cmd1, "--append-system-prompt") + 1], cmd2[find_flag(cmd2, "--append-system-prompt") + 1])
    end)

    it("picks up an edit on the next request", function()
      write_project_prompt({ "First revision." })
      local cmd1 = cli_command_builder.build("hello", {}, nil, {}, nil)
      local before = cmd1[find_flag(cmd1, "--append-system-prompt") + 1]

      write_project_prompt({ "Second revision." })
      local cmd2 = cli_command_builder.build("hello", {}, nil, {}, nil)
      local after = cmd2[find_flag(cmd2, "--append-system-prompt") + 1]

      assert.is_true(before:find("First revision.", 1, true) ~= nil)
      assert.is_true(after:find("Second revision.", 1, true) ~= nil)
      assert.is_nil(after:find("First revision.", 1, true))
    end)

    it("is not sent on lightweight (title/summary) calls", function()
      write_project_prompt({ "Project rule: always run the linter." })

      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

      assert.is_nil(prompt_text:find("always run the linter", 1, true))
    end)

    describe("with a worktree working_dir (opts.cwd)", function()
      local worktree_root

      local function write_worktree_prompt(lines)
        vim.fn.mkdir(worktree_root .. "/.vibing", "p")
        vim.fn.writefile(lines, worktree_root .. "/.vibing/system-prompt.md")
      end

      before_each(function()
        worktree_root = project_root .. "/.vibing/worktrees/feature-x"
        vim.fn.mkdir(worktree_root, "p")
      end)

      it("prefers the worktree's own file over the project root's", function()
        write_project_prompt({ "Root rule." })
        write_worktree_prompt({ "Worktree rule." })

        local cmd = cli_command_builder.build("hello", { cwd = worktree_root }, nil, {}, nil)
        local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

        assert.is_true(prompt_text:find("Worktree rule.", 1, true) ~= nil)
        assert.is_nil(prompt_text:find("Root rule.", 1, true))
      end)

      it("falls back to the project root when the worktree has no file", function()
        write_project_prompt({ "Root rule." })

        local cmd = cli_command_builder.build("hello", { cwd = worktree_root }, nil, {}, nil)
        local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

        assert.is_true(prompt_text:find("Root rule.", 1, true) ~= nil)
      end)

      it("falls back to the project root when the worktree file is empty", function()
        write_project_prompt({ "Root rule." })
        write_worktree_prompt({ "" })

        local cmd = cli_command_builder.build("hello", { cwd = worktree_root }, nil, {}, nil)
        local prompt_text = cmd[find_flag(cmd, "--append-system-prompt") + 1]

        assert.is_true(prompt_text:find("Root rule.", 1, true) ~= nil)
      end)
    end)
  end)

  describe("--allowedTools", function()
    it("always pre-approves both vibing-nvim MCP registration styles (plain and plugin-scoped)", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--allowedTools")
      assert.is_not_nil(idx)
      local allowed = cmd[idx + 1]
      assert.is_true(allowed:find("mcp__vibing-nvim__*", 1, true) ~= nil)
      -- The plugin-scoped prefix has to be the one build.sh actually installs
      -- (`vibing-nvim@vibing-nvim`); --allowedTools takes literal prefixes, so a stale
      -- marketplace name here silently matches nothing at all (#564).
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

    it('empties the tool set with --tools "" rather than enumerating a denylist', function()
      -- Why --tools and not the allow/deny flags: see cli_command_builder.lua's lightweight
      -- branch. The allow/deny assertions are the regression guard for #488 — the enumeration
      -- they replaced had already drifted (Agent/TaskCreate were never listed).
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--tools")
      assert.is_not_nil(idx)
      assert.equals("", cmd[idx + 1])
      assert.is_nil(find_flag(cmd, "--allowedTools"))
      assert.is_nil(find_flag(cmd, "--disallowedTools"))
    end)

    it("does not pass --settings even when a hook settings_path is provided", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, "/tmp/settings.json")
      assert.is_nil(find_flag(cmd, "--settings"))
    end)

    it("does not pass --permission-mode even when opts.permission_mode is set", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true, permission_mode = "acceptEdits" }, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "--permission-mode"))
    end)

    it("uses config.agent.utility_model, defaulting to sonnet when unset", function()
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, {}, nil)
      local idx = find_flag(cmd, "--model")
      assert.is_not_nil(idx)
      assert.equals("sonnet", cmd[idx + 1])
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
        { lightweight = true, chat_bufnr = 12 },
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
      assert.is_nil(prompt_text:find("Current vibing.nvim chat buffer number:", 1, true))
      assert.is_nil(prompt_text:find("nvim_highlight_range", 1, true))
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

  describe("--forward-subagent-text", function()
    it("is omitted by default", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "--forward-subagent-text"))
    end)

    it("is emitted when agent.subagent.enabled is true", function()
      local config = { agent = { subagent = { enabled = true } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      assert.is_not_nil(find_flag(cmd, "--forward-subagent-text"))
    end)

    it("is omitted when agent.subagent.enabled is false", function()
      local config = { agent = { subagent = { enabled = false, show_prefix = true } } }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)
      assert.is_nil(find_flag(cmd, "--forward-subagent-text"))
    end)

    it("is omitted for lightweight calls, which have no tools to delegate with", function()
      local config = { agent = { subagent = { enabled = true } } }
      local cmd = cli_command_builder.build("hello", { lightweight = true }, nil, config, nil)
      assert.is_nil(find_flag(cmd, "--forward-subagent-text"))
    end)
  end)
end)
