local Config = require("vibing.config")
local Ai = require("vibing.core.utils.ai_config")

describe("configuration redesign", function()
  after_each(function()
    Config.setup({})
  end)

  it("resolves purpose defaults and preserves all feature defaults", function()
    Config.setup({})
    local c = Config.get()
    assert.same({ agent = "claude", model = "sonnet", effort = "default" }, Ai.resolve(c))
    assert.same({ agent = "claude", model = "haiku", effort = "low" }, Ai.resolve(c, nil, true))
    assert.equals("current", c.ui.window.position)
    assert.equals("project", c.chat.storage.location)
    assert.equals(9876, c.integrations.nvim.port)
    assert.is_false(c.automation.limits.resume.enabled)
    assert.is_true(c.automation.limits.queue.enabled)
    assert.is_false(c.permissions.delegated_approval)
    assert.equals(".vibing/codex-permissions.toml", c.ai.agents.codex.extensions.profile_file)
    assert.matches("%[permissions%.vibing%-project%.network%]", c.ai.agents.codex.extensions.profile_content)
    assert.is_nil(c.ai.agents.grok.path)
  end)

  it("selects helper agent/model independently of the chat", function()
    Config.setup({
      ai = {
        chat = { agent = "codex", model = "chat-model", effort = "high" },
        helpers = { agent = "claude", model = "helper-model", effort = "medium" },
      },
    })
    assert.same({ agent = "claude", model = "helper-model", effort = "medium" }, Ai.resolve(Config.get(), nil, true))
    assert.same({ agent = "codex", model = "chat-model", effort = "high" }, Ai.resolve(Config.get()))
  end)

  it("inherits the chat agent but uses its own helper model default", function()
    Config.setup({ ai = { chat = { agent = "codex", model = "chat-model" } } })
    assert.same({ agent = "codex", effort = "low" }, Ai.resolve(Config.get(), nil, true))
    assert.is_nil(Ai.resolve(Config.get(), "copilot").model)
  end)

  it("merges objects and replaces lists, including empty lists", function()
    Config.setup({
      ui = { window = { position = "left" }, gradient = { colors = { "#123456", "#654321" } } },
      permissions = { allow = {}, deny = {} },
      ai = { agents = { claude = { settings = { sources = {} } } } },
    })
    local c = Config.get()
    assert.equals(0.4, c.ui.window.width)
    assert.same({ "#123456", "#654321" }, c.ui.gradient.colors)
    assert.same({ "Skill" }, c.permissions.allow)
    assert.same({}, c.permissions.deny)
    assert.same({}, c.ai.agents.claude.settings.sources)
  end)

  it("merges free-form marker objects while replacing permission lists", function()
    Config.setup({ ui = { tools = { markers = { Bash = "B" } } }, permissions = { deny = { "Write" } } })
    assert.equals("▶", Config.get().ui.tools.markers.Task)
    assert.equals("B", Config.get().ui.tools.markers.Bash)
    assert.same({ "Write" }, Config.get().permissions.deny)
  end)

  it("does not share defaults or input objects", function()
    local opts = { ai = { agents = { codex = { extensions = { auto_approve_ask = { "Bash(git push)" } } } } } }
    Config.setup(opts)
    Config.get().ai.agents.codex.extensions.auto_approve_ask[1] = "changed"
    Config.get().ui.window.position = "left"
    assert.equals("Bash(git push)", opts.ai.agents.codex.extensions.auto_approve_ask[1])
    assert.same({}, Config.defaults.ai.agents.codex.extensions.auto_approve_ask)
    assert.equals("current", Config.defaults.ui.window.position)
  end)

  it("accepts each agent's common parameters and native extensions", function()
    for _, id in ipairs({ "claude", "codex", "copilot", "grok" }) do
      Config.setup({
        ai = {
          agents = {
            [id] = {
              path = "/custom/agent",
              process = "oneshot",
              env = { TOKEN_LIMIT = 42 },
              settings = {},
              mcp = {},
              extensions = {},
            },
          },
        },
      })
      assert.equals("/custom/agent", Config.get().ai.agents[id].path)
      assert.equals(42, Config.get().ai.agents[id].env.TOKEN_LIMIT)
    end
    Config.setup({
      ai = {
        agents = {
          codex = { extensions = { profile_file = false, approval_policy = "on-request", auto_approve = true } },
          claude = { extensions = { git_instructions = true }, process = "duplex" },
        },
      },
    })
    assert.is_false(Config.get().ai.agents.codex.extensions.profile_file)
    assert.is_true(Config.get().ai.agents.claude.extensions.git_instructions)
  end)

  it("retains profiles and worker defaults without merging list entries", function()
    Config.setup({
      ai = { profiles = { { name = "implementer", tools = {} }, { name = "focused", model = "haiku" } } },
      automation = { orchestration = { worker_defaults = { model = "sonnet", profile = "focused" } } },
    })
    assert.equals(2, #Config.get().ai.profiles)
    assert.same({}, Config.get().ai.profiles[1].tools)
    assert.equals("haiku", Config.get().ai.profiles[2].model)
    assert.equals("focused", Config.get().automation.orchestration.worker_defaults.profile)
    Config.setup({ ai = { agents = { grok = { process = "duplex" } } } })
    assert.equals("duplex", Config.get().ai.agents.grok.process)
  end)

  it("preserves explicit Skill ask and deny", function()
    for _, key in ipairs({ "ask", "deny" }) do
      Config.setup({ permissions = { allow = {}, [key] = { "Skill" } } })
      assert.same({}, Config.get().permissions.allow)
    end
  end)

  it("keeps tool rules and delegated approvals without operations", function()
    local rule = { tools = { "Bash" }, commands = { "git status" }, action = "allow" }
    Config.setup({ permissions = { delegated_approval = "scoped", rules = { rule } } })
    assert.same({ rule }, Config.get().permissions.rules)
    assert.equals("scoped", Config.get().permissions.delegated_approval)
  end)

  it("reports paths and leaves the last valid config intact on error", function()
    Config.setup({ ui = { wrap = "off" } })
    local ok, err =
      pcall(Config.setup, { ai = { agents = { codex = { extensions = { approval_policy = "untrusted" } } } } })
    assert.is_false(ok)
    assert.matches("ai.agents.codex.extensions.approval_policy", err, 1, true)
    assert.equals("off", Config.get().ui.wrap)
  end)

  local invalid = {
    false,
    { ui = { gradient = { colors = { "#123456" } } } },
    { ui = { gradient = { waiting_color = "blue" } } },
    { adapter = "claude" },
    { agent = { default_mode = "plan" } },
    { backends = {} },
    { chat = { mode = "code" } },
    { ui = { gradient = { interval = 100 } } },
    { unknown = true },
    { ai = { profiles = { { model = "sonnet" } } } },
    { ai = { profiles = { { name = "bad name" } } } },
    { ai = { profiles = { { name = "worker", unknown = true } } } },
    { ai = { profiles = { { name = "worker", agent = "unknown" } } } },
    { ai = { profiles = { { name = "worker", effort = "extreme" } } } },
    { permissions = { operations = { read = true } } },
    { ui = { diff = { tool = "git" } } },
    { ai = { agents = { grok = { executable = "auto" } } } },
    { ai = { chat = { agent = "unknown" } } },
    { ai = { helpers = { model = "" } } },
    { ai = { agents = { codex = { settings = { sources = { "user" } } } } } },
    { ai = { agents = { copilot = { mcp = { inherit_cli_servers = false } } } } },
    { ai = { agents = { copilot = { process = "duplex" } } } },
    { ui = { diff = { fill_char = "xx" } } },
    { integrations = { nvim = { port = 65536 } } },
    { permissions = { rules = { { action = "allow" } } } },
    { permissions = { rules = { { tools = { "Bash" } } } } },
    { permissions = { allow = { [1] = "Read", [3] = "Write" } } },
    { ai = { agents = { codex = { extensions = { profile_file = true } } } } },
    { ai = { agents = { claude = { env = { FOO = true } } } } },
    { automation = { limits = { resume = { max_retries = 0.5 } } } },
  }
  for i, opts in ipairs(invalid) do
    it("rejects invalid or removed options " .. i, function()
      assert.has_error(function()
        Config.setup(opts)
      end)
    end)
  end
  it("names the replacement for legacy keys", function()
    local _, err = pcall(Config.setup, { chat = { window = { position = "left" } } })
    assert.matches("chat.window: moved to ui.window", err, 1, true)
  end)
end)
