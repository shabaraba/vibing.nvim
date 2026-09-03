local codex_command_builder = require("vibing.infrastructure.adapter.modules.codex_command_builder")

describe("codex_command_builder", function()
  local original_exepath

  before_each(function()
    codex_command_builder._reset_path_cache()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function(name)
      if name == "codex" then
        return "/usr/local/bin/codex"
      end
      return original_exepath(name)
    end
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
    codex_command_builder._reset_path_cache()
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  --- Every value passed with `-c`, so a test can assert on the set of config overrides.
  local function config_overrides(cmd)
    local overrides = {}
    for i, arg in ipairs(cmd) do
      if arg == "-c" and cmd[i + 1] then
        table.insert(overrides, cmd[i + 1])
      end
    end
    return overrides
  end

  describe("lightweight mode", function()
    -- Codex offers no `--tools ""` equivalent: probing the schema with `--strict-config` against
    -- codex 0.147 rejects tools.shell / tools.apply_patch / tools.view_image / tools.plan_tool /
    -- tools.mcp as unknown fields, leaving tools.web_search as the only tool toggle. So these
    -- assertions pin a sandbox, not an empty tool set -- fencing the tools in is all there is.
    it("confines the call to a read-only sandbox", function()
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'sandbox_mode="read-only"'))
    end)

    it("turns off the one tool codex can actually disable", function()
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), "tools.web_search=false"))
    end)

    it("never waits on an approval prompt that headless exec cannot show", function()
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'approval_policy="never"'))
    end)

    it("reaches none of the user's MCP servers", function()
      -- Not `-c mcp_servers={}`: it deep-merged, so it removed nothing. See the builder.
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_not_nil(find_flag(cmd, "--ignore-user-config"))
      assert.is_false(vim.tbl_contains(config_overrides(cmd), "mcp_servers={}"))
    end)

    it("rejects unknown config keys so a renamed one cannot unfence the call silently", function()
      -- A key codex renames or drops must fail the call rather than quietly stop applying (#574).
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_not_nil(find_flag(cmd, "--strict-config"))
    end)

    it("reads no AGENTS.md, the way the claude path reads no CLAUDE.md", function()
      -- Still needed alongside --ignore-user-config: AGENTS.md is found from the cwd.
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), "project_doc_max_bytes=0"))
    end)

    it("does not fall back to the workspace-write sandbox", function()
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      assert.is_nil(find_flag(cmd, "-s"))
      assert.is_false(vim.tbl_contains(config_overrides(cmd), 'sandbox_mode="workspace-write"'))
    end)

    it("stays read-only even when the chat is in bypassPermissions", function()
      -- The user put the chat in that mode; a title generated behind their back is not the call
      -- they made, so the utility call does not inherit it.
      local cmd = codex_command_builder.build(
        "hi",
        { lightweight = true, permission_mode = "bypassPermissions" },
        nil,
        {},
        nil
      )
      assert.is_nil(find_flag(cmd, "--dangerously-bypass-approvals-and-sandbox"))
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'sandbox_mode="read-only"'))
    end)

    it("still restricts a resumed session, where -s is not accepted", function()
      -- /summarize passes the chat's session id, so this is the common case, not the edge one.
      local cmd = codex_command_builder.build("hi", { lightweight = true }, "thread-1", {}, nil)
      assert.is_nil(find_flag(cmd, "-s"))
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'sandbox_mode="read-only"'))
    end)

    it("uses utility_model rather than default_model", function()
      local config = { agent = { default_model = "gpt-5-codex", utility_model = "gpt-5-mini" } }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      assert.equals("gpt-5-mini", cmd[find_flag(cmd, "-m") + 1])
    end)

    it("passes no model when utility_model is a Claude name codex does not have", function()
      -- utility_model defaults to "sonnet"; the existing filter turns it into codex's own default
      -- instead of a model the CLI would reject.
      local config = { agent = { default_model = "gpt-5-codex", utility_model = "sonnet" } }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      assert.is_nil(find_flag(cmd, "-m"))
    end)
  end)

  describe("ordinary calls", function()
    it("are unaffected by the lightweight restrictions", function()
      local cmd = codex_command_builder.build("hi", {}, nil, {}, nil)
      local overrides = config_overrides(cmd)
      for _, restriction in ipairs({
        'sandbox_mode="read-only"',
        "tools.web_search=false",
        'approval_policy="never"',
        "project_doc_max_bytes=0",
      }) do
        assert.is_false(vim.tbl_contains(overrides, restriction), restriction .. " leaked")
      end
      -- An ordinary chat is where the user's MCP servers and their own config.toml are the point.
      assert.is_nil(find_flag(cmd, "--ignore-user-config"))
      assert.is_nil(find_flag(cmd, "--strict-config"))
      assert.equals("workspace-write", cmd[find_flag(cmd, "-s") + 1])
    end)

    it("still map plan mode to a read-only sandbox via -s", function()
      local cmd = codex_command_builder.build("hi", { permission_mode = "plan" }, nil, {}, nil)
      assert.equals("read-only", cmd[find_flag(cmd, "-s") + 1])
    end)

    it("still bypass the sandbox in bypassPermissions", function()
      local opts = { permission_mode = "bypassPermissions" }
      local cmd = codex_command_builder.build("hi", opts, nil, {}, nil)
      assert.is_not_nil(find_flag(cmd, "--dangerously-bypass-approvals-and-sandbox"))
    end)

    it("use default_model, not utility_model", function()
      local config = { agent = { default_model = "gpt-5-codex", utility_model = "gpt-5-mini" } }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      assert.equals("gpt-5-codex", cmd[find_flag(cmd, "-m") + 1])
    end)
  end)

  -- Codex has no `--plugin-dir`; the plugins ride along as `-c` overrides instead
  -- (codex_plugin_config). What is pinned here is *where* they go: on every ordinary call,
  -- resumed or not, and never on a lightweight one.
  describe("plugins", function()
    local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
    local no_project = { agent = { plugins = { project_dir = false } } }

    local function has_override(cmd, prefix)
      for _, item in ipairs(config_overrides(cmd)) do
        if vim.startswith(item, prefix) then
          return true
        end
      end
      return false
    end

    before_each(function()
      PluginDirs.clear_cache()
    end)

    after_each(function()
      PluginDirs.clear_cache()
    end)

    it("registers vibing.nvim's own MCP server and skills on an ordinary request", function()
      local cmd = codex_command_builder.build("hello", {}, nil, no_project, nil)
      assert.is_true(has_override(cmd, "mcp_servers.vibing-nvim.command="))
      assert.is_true(has_override(cmd, "developer_instructions="))
    end)

    it("keeps them on a resumed session, since config is per process", function()
      local cmd = codex_command_builder.build("hello", {}, "thread-1", no_project, nil)
      assert.is_true(has_override(cmd, "mcp_servers.vibing-nvim.command="))
      assert.is_true(has_override(cmd, "developer_instructions="))
    end)

    it("passes the rpc_port into the developer message", function()
      local cmd = codex_command_builder.build("hello", {}, nil, no_project, nil, 4321)
      local found = false
      for _, item in ipairs(config_overrides(cmd)) do
        if vim.startswith(item, "developer_instructions=") and item:find("rpc_port for this turn is 4321", 1, true) then
          found = true
        end
      end
      assert.is_true(found)
    end)

    -- A utility call owes "no tools, no user MCP servers" (core/types.lua); the bundled server
    -- and a skill list are both.
    it("loads none of it on a lightweight call", function()
      local cmd = codex_command_builder.build("hello", { lightweight = true }, nil, no_project, nil, 4321)
      assert.is_false(has_override(cmd, "mcp_servers."))
      assert.is_false(has_override(cmd, "developer_instructions="))
    end)

    it("loads none of it when agent.plugins.self is off and no project plugin exists", function()
      local cmd = codex_command_builder.build("hello", {}, nil, { agent = { plugins = { self = false, project_dir = false } } }, nil)
      assert.is_false(has_override(cmd, "mcp_servers."))
      assert.is_false(has_override(cmd, "developer_instructions="))
    end)

    it("keeps the prompt as the last argument", function()
      local cmd = codex_command_builder.build("hello", {}, nil, no_project, nil)
      assert.equals("hello", cmd[#cmd])
    end)
  end)

  -- Checked structurally rather than on one fixture, because the risk is a *future* build that
  -- sends --strict-config down a path where --ignore-user-config is gated more narrowly. Alone,
  -- --strict-config also strictifies the user's own config.toml, so one unrecognised field of
  -- theirs would break the call -- which is exactly why #571 rejected the flag in the first place.
  describe("--strict-config never travels alone", function()
    for _, case in ipairs({
      { name = "lightweight, new session", opts = { lightweight = true }, session = nil },
      { name = "lightweight, resumed", opts = { lightweight = true }, session = "thread-1" },
      {
        name = "lightweight in bypassPermissions",
        opts = { lightweight = true, permission_mode = "bypassPermissions" },
        session = nil,
      },
      { name = "ordinary call", opts = {}, session = nil },
      { name = "ordinary plan mode", opts = { permission_mode = "plan" }, session = nil },
      { name = "ordinary resumed", opts = {}, session = "thread-1" },
    }) do
      it("holds for " .. case.name, function()
        local cmd = codex_command_builder.build("hi", case.opts, case.session, {}, nil)
        if find_flag(cmd, "--strict-config") then
          assert.is_not_nil(
            find_flag(cmd, "--ignore-user-config"),
            "--strict-config without --ignore-user-config would strictify the user's config.toml"
          )
        end
      end)
    end
  end)
end)
