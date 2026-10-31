local codex_command_builder = require("vibing.infrastructure.adapter.modules.codex_command_builder")
local lightweight_provider = require("vibing.infrastructure.adapter.modules.codex_lightweight_provider")

describe("codex_command_builder", function()
  local original_exepath

  before_each(function()
    codex_command_builder._reset_path_cache()
    -- A developer config.toml must not leak into these argv assertions.
    lightweight_provider._set_config_path(false)
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
    lightweight_provider._reset()
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  it("passes the output schema file for a search request", function()
    local cmd = codex_command_builder.build("search", { output_schema_path = "/tmp/schema.json" }, nil, {}, nil)
    assert.are.equal("/tmp/schema.json", cmd[find_flag(cmd, "--output-schema") + 1])
    assert.is_nil(find_flag(codex_command_builder.build("chat", {}, nil, {}, nil), "--output-schema"))
  end)

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

  describe("reasoning effort", function()
    it("maps the frontmatter effort to a per-run Codex config override", function()
      local cmd = codex_command_builder.build("hi", { effort = "xhigh" }, nil, {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'model_reasoning_effort="xhigh"'))
    end)

    it("falls back to ai.chat.effort", function()
      local config = {
        ai = {
          chat = {
            agent = "codex",
            effort = "high",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'model_reasoning_effort="high"'))
    end)

    it("leaves the Codex default alone when no effort is configured", function()
      local cmd = codex_command_builder.build("hi", {}, nil, {}, nil)
      for _, override in ipairs(config_overrides(cmd)) do
        assert.is_false(vim.startswith(override, "model_reasoning_effort="))
      end
    end)

    it("leaves the Codex default alone for effort: default", function()
      local cmd = codex_command_builder.build("hi", { effort = "default" }, nil, {}, nil)
      for _, override in ipairs(config_overrides(cmd)) do
        assert.is_false(vim.startswith(override, "model_reasoning_effort="))
      end
    end)

    it("uses utility_effort for lightweight calls instead of the chat effort", function()
      local config = {
        ai = {
          chat = {
            agent = "codex",
            effort = "high",
          },
          helpers = {
            effort = "low",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", { lightweight = true, effort = "max" }, nil, config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'model_reasoning_effort="low"'))
      assert.is_false(vim.tbl_contains(config_overrides(cmd), 'model_reasoning_effort="max"'))
    end)

    it("keeps the override on resumed threads", function()
      local cmd = codex_command_builder.build("hi", { effort = "medium" }, "thread-1", {}, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'model_reasoning_effort="medium"'))
    end)
  end)

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
      local config = {
        ai = {
          chat = {
            agent = "codex",
            model = "gpt-5-codex",
          },
          helpers = {
            model = "gpt-5-mini",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      assert.equals("gpt-5-mini", cmd[find_flag(cmd, "-m") + 1])
    end)

    it("passes no model when utility_model is a Claude name codex does not have", function()
      -- utility_model defaults to "haiku"; the existing filter turns it into codex's own default
      -- instead of a model the CLI would reject.
      local config = {
        ai = {
          chat = {
            agent = "codex",
            model = "gpt-5-codex",
          },
          helpers = {
            model = "haiku",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      assert.is_nil(find_flag(cmd, "-m"))
    end)

    it("sends a custom provider, its definition and the configured model", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/config.toml"
      local written = vim.fn.writefile(vim.split(
        table.concat({
          'model = "local-large" # the chat default',
          'model_provider = "myprov"',
          'openai_base_url = "https://proxy.example/v1"',
          "",
          "[model_providers.myprov]",
          'name = "Local"',
          'base_url = "http://127.0.0.1:11434/v1"',
          'wire_api = "chat"',
          'env_key = "LOCAL#KEY"',
          "requires_openai_auth = false",
          'http_headers = { "X-Custom" = "yes" }',
          "",
          "[model_providers.myprov.auth]",
          'command = "/usr/bin/token"',
          'args = ["--audience", "codex"]',
          "",
          "[model_providers.other]",
          'base_url = "http://127.0.0.1:9/v1"',
          "",
          "[mcp_servers.probe]",
          'command = "touch"',
          'args = ["/tmp/owned"]',
          "",
          "[profiles.work]",
          'model_provider = "other"',
          'model = "nope"',
          "",
        }, "\n"),
        "\n",
        { plain = true }
      ), path)
      assert.equals(0, written, "failed to write " .. path)
      lightweight_provider._set_config_path(path)

      local cmd = codex_command_builder.build("hi", { lightweight = true }, "thread-1", {}, nil)
      local overrides = config_overrides(cmd)
      assert.is_true(vim.tbl_contains(overrides, 'model_provider="myprov"'))
      assert.is_true(vim.tbl_contains(overrides, 'model="local-large"'))
      assert.is_true(vim.tbl_contains(overrides, 'openai_base_url="https://proxy.example/v1"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.base_url="http://127.0.0.1:11434/v1"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.wire_api="chat"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.env_key="LOCAL#KEY"'))
      assert.is_true(vim.tbl_contains(overrides, "model_providers.myprov.requires_openai_auth=false"))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.name="Local"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.http_headers={ "X-Custom" = "yes" }'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.auth.command="/usr/bin/token"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.auth.args=["--audience", "codex"]'))
      assert.is_false(vim.tbl_contains(overrides, 'model_providers.other.base_url="http://127.0.0.1:9/v1"'))
      assert.is_false(vim.tbl_contains(overrides, 'model="nope"'))
      for _, override in ipairs(overrides) do
        assert.is_nil(override:find("mcp_servers", 1, true), override)
        assert.is_nil(override:find("touch", 1, true), override)
      end
      -- The fence that keeps MCP servers out is still there.
      assert.is_not_nil(find_flag(cmd, "--ignore-user-config"))
      vim.fn.delete(dir, "rf")
    end)

    it("keeps a configured helper model and still uses the custom provider", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/config.toml"
      vim.fn.writefile({
        'model = "local-large"',
        'model_provider = "myprov"',
        "",
        "[model_providers.myprov]",
        'name = "Local"',
        'base_url = "http://127.0.0.1:11434/v1"',
        'wire_api = "chat"',
      }, path)
      lightweight_provider._set_config_path(path)

      local config = {
        ai = {
          chat = { agent = "codex", model = "gpt-5-codex" },
          helpers = { model = "local-small" },
        },
      }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      local overrides = config_overrides(cmd)
      assert.equals("local-small", cmd[find_flag(cmd, "-m") + 1])
      assert.is_true(vim.tbl_contains(overrides, 'model_provider="myprov"'))
      assert.is_true(vim.tbl_contains(overrides, 'model_providers.myprov.base_url="http://127.0.0.1:11434/v1"'))
      assert.is_false(vim.tbl_contains(overrides, 'model="local-large"'))
      assert.is_false(vim.tbl_contains(cmd, "gpt-5-codex"))
      vim.fn.delete(dir, "rf")
    end)

    it("leaves an ordinary call on Codex's own config", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/config.toml"
      vim.fn.writefile({
        'model = "local-large"',
        'model_provider = "myprov"',
        "",
        "[model_providers.myprov]",
        'base_url = "http://127.0.0.1:11434/v1"',
      }, path)
      lightweight_provider._set_config_path(path)

      local cmd = codex_command_builder.build("hi", {}, nil, {}, nil)
      for _, override in ipairs(config_overrides(cmd)) do
        assert.is_nil(override:find("model_provider=", 1, true), override)
        assert.is_nil(override:find("model_providers.", 1, true), override)
        assert.is_nil(override:find("model=", 1, true), override)
      end
      assert.is_nil(find_flag(cmd, "--ignore-user-config"))
      vim.fn.delete(dir, "rf")
    end)

    it("does not retarget the default OpenAI provider", function()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local path = dir .. "/config.toml"
      vim.fn.writefile({
        'model = "gpt-5.4"',
        'model_provider = "openai"',
        "",
        "[model_providers.myprov]",
        'base_url = "http://127.0.0.1:9/v1"',
      }, path)
      lightweight_provider._set_config_path(path)

      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, {}, nil)
      local overrides = config_overrides(cmd)
      assert.is_true(vim.tbl_contains(overrides, 'model="gpt-5.4"'))
      for _, override in ipairs(overrides) do
        assert.is_nil(override:find("model_provider=", 1, true), override)
        assert.is_nil(override:find("model_providers.", 1, true), override)
      end
      vim.fn.delete(dir, "rf")
    end)

    it("does not apply the chat's auto-compaction threshold", function()
      local config = {
        chat = {
          agent = "codex",
          context = {
            compaction = {
              enabled = true,
              threshold_tokens = 300000,
            },
          },
        },
      }
      local cmd = codex_command_builder.build("hi", { lightweight = true }, nil, config, nil)
      assert.is_false(vim.tbl_contains(config_overrides(cmd), "model_auto_compact_token_limit=300000"))
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
      local config = {
        ai = {
          chat = {
            agent = "codex",
            model = "gpt-5-codex",
          },
          helpers = {
            model = "gpt-5-mini",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      assert.equals("gpt-5-codex", cmd[find_flag(cmd, "-m") + 1])
    end)

    it("prefer the frontmatter model passed through opts", function()
      local config = {
        ai = {
          chat = {
            agent = "codex",
            model = "gpt-5.5",
          },
        },
      }
      local cmd = codex_command_builder.build("hi", { model = "gpt-5.6-terra" }, nil, config, nil)
      assert.equals("gpt-5.6-terra", cmd[find_flag(cmd, "-m") + 1])
    end)

    it("lets model: default bypass ai.chat.model", function()
      local cmd = codex_command_builder.build("hi", { model = "default" }, nil, {
        ai = {
          chat = {
            agent = "codex",
            model = "gpt-6-sol",
          },
        },
      }, nil)
      assert.is_nil(find_flag(cmd, "-m"))
    end)

    it("maps the shared auto_compact threshold to Codex's native setting", function()
      local config = {
        chat = {
          agent = "codex",
          context = {
            compaction = {
              enabled = true,
              threshold_tokens = 300000,
            },
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), "model_auto_compact_token_limit=300000"))
    end)

    it("clamps a positive fractional auto_compact threshold below one to one token", function()
      local config = {
        chat = {
          agent = "codex",
          context = {
            compaction = {
              enabled = true,
              threshold_tokens = 0.5,
            },
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), "model_auto_compact_token_limit=1"))
    end)

    it("keeps the native threshold on resumed threads", function()
      local config = {
        chat = {
          agent = "codex",
          context = {
            compaction = {
              enabled = true,
              threshold_tokens = 300000,
            },
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, "thread-1", config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), "model_auto_compact_token_limit=300000"))
    end)

    it("uses the shared default when auto_compact.at is omitted", function()
      local config = {
        chat = {
          agent = "codex",
          context = {
            compaction = {
              enabled = true,
            },
          },
        },
      }
      local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
      local expected = "model_auto_compact_token_limit="
        .. require("vibing.core.utils.token_usage").DEFAULT_AUTO_COMPACT_AT
      assert.is_true(vim.tbl_contains(config_overrides(cmd), expected))
    end)

    it("does not override Codex when auto_compact is disabled or its threshold is non-positive", function()
      for _, auto_compact in ipairs({
        { enabled = false, threshold_tokens = 300000 },
        { enabled = true, threshold_tokens = 0 },
        { enabled = true, threshold_tokens = -1 },
      }) do
        local config = {
          chat = {
            agent = "codex",
            context = {
              compaction = auto_compact,
            },
          },
        }
        local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
        for _, override in ipairs(config_overrides(cmd)) do
          assert.is_false(vim.startswith(override, "model_auto_compact_token_limit="))
        end
      end
    end)
  end)

  describe("project-local Codex permission profile", function()
    local root
    local config

    before_each(function()
      root = vim.fn.tempname()
      vim.fn.mkdir(root .. "/.vibing", "p")
      vim.fn.writefile({
        'default_permissions = "project-edit"',
        "[permissions.project-edit]",
        'extends = ":workspace"',
        '[permissions.project-edit.filesystem.":workspace_roots"]',
        '".git" = "write"',
      }, root .. "/.vibing/codex-permissions.toml")
      config = {
        ai = {
          agents = {
            codex = {
              extensions = {
                profile_file = ".vibing/codex-permissions.toml",
              },
            },
          },
        },
        integrations = {
          plugins = { self = false, project_dir = false },
        },
      }
    end)

    after_each(function()
      vim.fn.delete(root, "rf")
    end)

    it("replaces -s with config overrides on a new session", function()
      local cmd = codex_command_builder.build("hi", { cwd = root }, nil, config, nil)
      local overrides = config_overrides(cmd)
      assert.is_nil(find_flag(cmd, "-s"))
      assert.is_true(vim.tbl_contains(overrides, 'default_permissions="project-edit"'))
      assert.is_true(
        vim.tbl_contains(
          overrides,
          'permissions={ project-edit = { extends = ":workspace", filesystem = { ":workspace_roots" = { ".git" = "write" } } } }'
        )
      )
    end)

    it("is repeated unchanged when resuming because config is per process", function()
      local fresh = codex_command_builder.build("hi", { cwd = root }, nil, config, nil)
      local resumed = codex_command_builder.build("again", { cwd = root }, "thread-1", config, nil)
      assert.same(config_overrides(fresh), config_overrides(resumed))
    end)

    it("does not enter a lightweight utility call", function()
      local cmd = codex_command_builder.build("hi", { cwd = root, lightweight = true }, nil, config, nil)
      local overrides = config_overrides(cmd)
      assert.is_false(vim.tbl_contains(overrides, 'default_permissions="project-edit"'))
      assert.is_true(vim.tbl_contains(overrides, 'sandbox_mode="read-only"'))
    end)

    it("does not weaken plan mode", function()
      local fresh = codex_command_builder.build("hi", { cwd = root, permission_mode = "plan" }, nil, config, nil)
      assert.equals("read-only", fresh[find_flag(fresh, "-s") + 1])
      assert.is_false(vim.tbl_contains(config_overrides(fresh), 'default_permissions="project-edit"'))

      local resumed =
        codex_command_builder.build("hi", { cwd = root, permission_mode = "plan" }, "thread-1", config, nil)
      assert.is_true(vim.tbl_contains(config_overrides(resumed), 'sandbox_mode="read-only"'))
      assert.is_false(vim.tbl_contains(config_overrides(resumed), 'default_permissions="project-edit"'))
    end)

    it("keeps bypassPermissions explicit on new and resumed sessions", function()
      for _, session_id in ipairs({ false, "thread-1" }) do
        local cmd = codex_command_builder.build(
          "hi",
          { cwd = root, permission_mode = "bypassPermissions" },
          session_id or nil,
          config,
          nil
        )
        assert.is_not_nil(find_flag(cmd, "--dangerously-bypass-approvals-and-sandbox"))
        assert.is_false(vim.tbl_contains(config_overrides(cmd), 'default_permissions="project-edit"'))
      end
    end)
  end)

  -- Codex has no `--plugin-dir`; the plugins ride along as `-c` overrides instead
  -- (codex_plugin_config). What is pinned here is *where* they go: on every ordinary call,
  -- resumed or not, and never on a lightweight one.
  describe("plugins", function()
    local PluginDirs = require("vibing.infrastructure.plugins.plugin_dirs")
    local no_project = {
      integrations = {
        plugins = { project_dir = false },
      },
    }

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
      require("vibing.infrastructure.adapter.modules.codex_plugin_config").clear_cache()
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
      local cmd = codex_command_builder.build("hello", { chat_bufnr = 12 }, "thread-1", no_project, nil)
      assert.is_true(has_override(cmd, "mcp_servers.vibing-nvim.command="))
      assert.is_true(has_override(cmd, "developer_instructions="))
      assert.is_true(
        table.concat(config_overrides(cmd), "\n"):find("Current vibing.nvim chat buffer number: 12", 1, true) ~= nil
      )
    end)

    it("carries chat_bufnr in the developer instructions on a fresh session", function()
      local cmd = codex_command_builder.build("hello", { chat_bufnr = 34 }, nil, no_project, nil)
      assert.is_true(
        table.concat(config_overrides(cmd), "\n"):find("Current vibing.nvim chat buffer number: 34", 1, true) ~= nil
      )
    end)

    it("keeps the runtime rpc_port out of the developer message", function()
      local cmd = codex_command_builder.build("hello", {}, nil, no_project, nil)
      for _, item in ipairs(config_overrides(cmd)) do
        if vim.startswith(item, "developer_instructions=") then
          assert.is_nil(item:find("rpc_port for this turn", 1, true))
        end
      end
      assert.is_true(has_override(cmd, "mcp_servers.vibing-nvim.env_vars="))
    end)

    -- A utility call owes "no tools, no user MCP servers" (core/types.lua); the bundled server
    -- and a skill list are both.
    it("loads none of it on a lightweight call", function()
      local cmd = codex_command_builder.build("hello", { lightweight = true, chat_bufnr = 12 }, nil, no_project, nil)
      assert.is_false(has_override(cmd, "mcp_servers."))
      assert.is_false(has_override(cmd, "developer_instructions="))
      assert.is_nil(table.concat(config_overrides(cmd), "\n"):find("Current vibing.nvim chat buffer number:", 1, true))
    end)

    it("loads none of it when integrations.plugins.self is off and no project plugin exists", function()
      local cmd = codex_command_builder.build("hello", {}, nil, {
        integrations = {
          plugins = { self = false, project_dir = false },
        },
      }, nil)
      assert.is_false(has_override(cmd, "mcp_servers."))
      assert.is_false(has_override(cmd, "developer_instructions="))
    end)

    it("keeps the prompt as the last argument", function()
      local cmd = codex_command_builder.build("hello", {}, nil, no_project, nil)
      assert.equals("hello", cmd[#cmd])
    end)
  end)

  -- `ai.agents.codex.extensions.approval_policy` decides when codex asks the human before running something,
  -- which is the switch that makes its own approval requests happen at all (#861). A separate dial
  -- from `permission_mode`, with one rule about where the two meet.
  describe("approval policy", function()
    local function policy(value)
      return {
        ai = {
          agents = {
            codex = {
              extensions = {
                approval_policy = value,
              },
            },
          },
        },
      }
    end

    it("falls back to never on duplex when it is unset, rather than to codex's own default", function()
      -- Not tidiness. A request this transport cannot route to a human is declined, so under
      -- codex's default policy an unconfigured chat turns a sandboxed action into a silent denial
      -- instead of something vibing's own hook and permission rules get to decide (#860).
      for _, config in ipairs({ {}, policy("") }) do
        local cmd = codex_command_builder.build("hi", { _process_model = "duplex" }, nil, config, nil)
        assert.is_true(vim.tbl_contains(config_overrides(cmd), 'approval_policy="never"'))
      end
    end)

    it("emits nothing when it is unset on a oneshot call, which has no such channel to fail on", function()
      for _, config in ipairs({ {}, policy("") }) do
        local cmd = codex_command_builder.build("hi", {}, nil, config, nil)
        for _, override in ipairs(config_overrides(cmd)) do
          assert.is_nil(override:match("^approval_policy="), "an unset policy must add no override")
        end
      end
    end)

    it("reaches the resident process, where it decides whether Codex ever asks", function()
      local cmd = codex_command_builder.build("hi", { _process_model = "duplex" }, nil, policy("on-request"), nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'approval_policy="on-request"'))
    end)

    it("reaches a oneshot call too", function()
      local cmd = codex_command_builder.build("hi", {}, nil, policy("on-request"), nil)
      assert.is_true(vim.tbl_contains(config_overrides(cmd), 'approval_policy="on-request"'))
    end)

    it("does not undo the two modes that already said what they want about asking", function()
      -- `bypassPermissions` means "ask nothing" and `plan` means "write nothing"; a configured
      -- policy that overrode either would turn an explicit choice about this chat into a surprise.
      for _, mode in ipairs({ "bypassPermissions", "plan" }) do
        for _, model in ipairs({ "duplex", "oneshot" }) do
          local cmd = codex_command_builder.build(
            "hi",
            { _process_model = model, permission_mode = mode },
            nil,
            policy("on-request"),
            nil
          )
          assert.is_false(
            vim.tbl_contains(config_overrides(cmd), 'approval_policy="on-request"'),
            mode .. " on " .. model .. " must not take the configured policy"
          )
        end
      end

      -- …and what each of those modes does say instead is unchanged by this feature.
      local duplex_bypass = codex_command_builder.build(
        "hi",
        { _process_model = "duplex", permission_mode = "bypassPermissions" },
        nil,
        policy("on-request"),
        nil
      )
      assert.is_true(vim.tbl_contains(config_overrides(duplex_bypass), 'approval_policy="never"'))

      local oneshot_bypass =
        codex_command_builder.build("hi", { permission_mode = "bypassPermissions" }, nil, policy("on-request"), nil)
      assert.is_not_nil(find_flag(oneshot_bypass, "--dangerously-bypass-approvals-and-sandbox"))
    end)

    it("does not grow the argv across turns by appending to the memoised profile", function()
      -- `CodexPermissionProfile.args` is cached per cwd. Extending what it returned would append to
      -- the cache, so the second turn's argv would carry two copies and the third three.
      local config = policy("on-request")
      local first = codex_command_builder.build("hi", { _process_model = "duplex" }, nil, config, nil)
      local second = codex_command_builder.build("hi", { _process_model = "duplex" }, nil, config, nil)
      assert.same(first, second)
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
