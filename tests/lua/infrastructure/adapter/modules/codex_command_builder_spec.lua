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
