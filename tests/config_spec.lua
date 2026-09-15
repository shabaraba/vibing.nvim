-- Tests for vibing.config module

describe("vibing.config", function()
  local config

  before_each(function()
    -- Reload module before each test.
    -- `notify` も一緒に捨てるのは、削除設定の案内が `notify.warn_once` の memo に載っている
    -- ため。configだけ作り直しても、前のテストが立てたフラグが残って警告が出なくなる
    package.loaded["vibing.core.utils.notify"] = nil
    package.loaded["vibing.config"] = nil
    config = require("vibing.config")
  end)

  describe("defaults", function()
    it("should have chat configuration", function()
      assert.is_not_nil(config.defaults.chat)
      assert.is_not_nil(config.defaults.chat.window)
      assert.equals("current", config.defaults.chat.window.position)
    end)

    it("should have agent configuration", function()
      assert.is_not_nil(config.defaults.agent)
      assert.equals("code", config.defaults.agent.default_mode)
      assert.equals("sonnet", config.defaults.agent.default_model)
      assert.equals("default", config.defaults.agent.default_effort)
    end)

    it("should have permissions configuration", function()
      assert.is_not_nil(config.defaults.permissions)
      assert.is_not_nil(config.defaults.permissions.allow)
      assert.is_table(config.defaults.permissions.allow)
      assert.is_not_nil(config.defaults.permissions.rules)
      assert.is_table(config.defaults.permissions.rules)
    end)

    it("should have per-backend configuration declared by the backends themselves", function()
      -- The fields come from `config_fields` in core/constants/agents.lua, so config.lua names no
      -- backend (ADR 009).
      assert.equals(".vibing/codex-permissions.toml", config.defaults.backends.codex.profile_file)
      assert.matches("%[permissions%.vibing%-project%.network%]", config.defaults.backends.codex.profile_content)
      assert.matches("enabled = true", config.defaults.backends.codex.profile_content)
      assert.is_false(config.defaults.backends.codex.allow_tracked_profile)
      assert.is_true(config.defaults.backends.codex.provider_notice)
      assert.equals("auto", config.defaults.backends.grok.executable)
      assert.same({}, config.defaults.backends.claude)
    end)

    it("should have language configuration", function()
      assert.is_nil(config.defaults.language)
    end)
  end)

  describe("setup", function()
    it("should merge user config with defaults", function()
      local user_config = {
        chat = {
          window = {
            position = "left",
          },
        },
      }

      config.setup(user_config)
      local result = config.get()

      -- User values should override defaults
      assert.equals("left", result.chat.window.position)

      -- Non-overridden defaults should remain
      assert.is_not_nil(result.agent)
      assert.equals("code", result.agent.default_mode)
    end)

    it("should warn about invalid tools in permissions", function()
      local user_config = {
        permissions = {
          allow = { "Read", "InvalidTool" },
        },
      }
      -- Should not error, just warn
      assert.has_no.errors(function()
        config.setup(user_config)
      end)
    end)

    it("should validate the Codex permission profile options by their declared kind", function()
      config.setup({ backends = { codex = { profile_file = false } } })
      assert.is_false(config.get().backends.codex.profile_file)

      config.setup({ backends = { codex = { profile_file = true } } })
      assert.equals(".vibing/codex-permissions.toml", config.get().backends.codex.profile_file)

      config.setup({ backends = { codex = { allow_tracked_profile = "yes" } } })
      assert.is_false(config.get().backends.codex.allow_tracked_profile)

      config.setup({ backends = { codex = { allow_tracked_profile = true } } })
      assert.is_true(config.get().backends.codex.allow_tracked_profile)

      config.setup({ backends = { codex = { profile_content = false } } })
      assert.equals(config.defaults.backends.codex.profile_content, config.get().backends.codex.profile_content)
    end)

    it("should validate the grok executable without resetting a missing path", function()
      config.setup({ backends = { grok = { executable = "" } } })
      assert.equals("auto", config.get().backends.grok.executable)

      -- A path that does not exist is kept: the user asked for that binary, and falling back to
      -- whatever `grok` is on PATH would be worse than failing.
      config.setup({ backends = { grok = { executable = "/nonexistent/grok" } } })
      assert.equals("/nonexistent/grok", config.get().backends.grok.executable)
    end)

    it("should migrate the pre-ADR-009 option locations into backends.<id>", function()
      config.setup({
        permissions = { codex_profile_file = false, codex_allow_tracked_profile = true },
        grok = { executable = "/opt/grok/bin/grok" },
        agent = { codex_provider_notice = { enabled = false } },
      })
      local backends = config.get().backends
      assert.is_false(backends.codex.profile_file)
      assert.is_true(backends.codex.allow_tracked_profile)
      assert.is_false(backends.codex.provider_notice)
      assert.equals("/opt/grok/bin/grok", backends.grok.executable)
      -- The stale keys do not survive into a table nothing reads.
      assert.is_nil(config.get().permissions.codex_profile_file)
      assert.is_nil(vim.tbl_get(config.get(), "grok", "executable"))
    end)

    it("prefers the new location when an option is set in both", function()
      config.setup({
        permissions = { codex_profile_file = false },
        backends = { codex = { profile_file = "custom.toml" } },
      })
      assert.equals("custom.toml", config.get().backends.codex.profile_file)
    end)
  end)

  describe("get", function()
    it("should return current config", function()
      config.setup({
        agent = {
          default_mode = "plan"
        }
      })
      local result = config.get()
      assert.equals("plan", result.agent.default_mode)
    end)
  end)
  describe("removed mote settings", function()
    local messages
    local original_notify

    before_each(function()
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("treats diff.tool = 'mote' as 'git' and says so", function()
      config.setup({ diff = { tool = "mote" } })

      assert.equals("git", config.get().diff.tool)
      assert.equals(1, #messages)
      assert.is_truthy(messages[1].msg:find("mote", 1, true))
    end)

    it("drops diff.mote and says so", function()
      config.setup({ diff = { mote = { context_prefix = "vibing" } } })

      assert.is_nil(config.get().diff.mote)
      assert.equals(1, #messages)
      assert.is_truthy(messages[1].msg:find("diff.mote", 1, true))
    end)

    it("warns only once even when setup() runs again", function()
      -- 正規化した値は M.options にしか書かないので、ユーザーの opts には古い設定が残る。
      -- ガードが無いと setup() を呼ぶたびに同じ警告が出る
      local opts = { diff = { tool = "mote", mote = { context_prefix = "vibing" } } }
      config.setup(opts)
      local after_first = #messages

      config.setup(opts)

      assert.equals(2, after_first)
      assert.equals(after_first, #messages)
      assert.equals("git", config.get().diff.tool)
      assert.is_nil(config.get().diff.mote)
    end)

    it("says nothing for a config that never mentioned mote", function()
      config.setup({ diff = { tool = "auto" } })

      assert.equals(0, #messages)
    end)
  end)

  describe("removed chat_notifications.max_hops", function()
    local messages
    local original_notify

    before_each(function()
      messages = {}
      original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg = msg, level = level })
      end
    end)

    after_each(function()
      vim.notify = original_notify
    end)

    it("drops it and names the settings that replaced it", function()
      -- 黙って無視すると「上限を下げたはずなのに効いていない」に気づけない
      config.setup({ agent = { chat_notifications = { enabled = true, max_hops = 2 } } })

      assert.is_nil(config.get().agent.chat_notifications.max_hops)
      assert.equals(1, #messages)
      assert.is_truthy(messages[1].msg:find("max_round_trips", 1, true))
      assert.is_truthy(messages[1].msg:find("max_wakes", 1, true))
    end)

    it("keeps the replacement defaults when the removed key was set", function()
      config.setup({ agent = { chat_notifications = { enabled = true, max_hops = 2 } } })

      local notifications = config.get().agent.chat_notifications
      assert.equals(8, notifications.max_round_trips)
      assert.equals(50, notifications.max_wakes)
    end)

    it("warns only once even when setup() runs again", function()
      local opts = { agent = { chat_notifications = { enabled = true, max_hops = 2 } } }
      config.setup(opts)
      config.setup(opts)

      assert.equals(1, #messages)
    end)

    it("says nothing for a config that never mentioned max_hops", function()
      config.setup({ agent = { chat_notifications = { enabled = true } } })

      assert.equals(0, #messages)
    end)
  end)
end)
