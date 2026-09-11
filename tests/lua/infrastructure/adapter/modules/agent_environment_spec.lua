--- The rules `agent.env` / frontmatter `env:` are merged under, away from the spawn.
---
--- `claude_cli_spec` asserts the same feature through a real `stream()` call, which is what the
--- acceptance criteria ask for; this file is where the branches that never reach a spawn live --
--- a malformed entry, a reserved key, a value with no obvious spelling.

local AgentEnvironment = require("vibing.infrastructure.adapter.modules.agent_environment")

--- @param agent_env table? config.agent.env
--- @param frontmatter_env any? the raw `env` frontmatter value
--- @param opts table? extra adapter opts
local function apply(agent_env, frontmatter_env, opts)
  local env = { PATH = "/usr/bin" }
  AgentEnvironment.apply(
    env,
    { agent = { env = agent_env } },
    vim.tbl_extend("force", { env = frontmatter_env }, opts or {})
  )
  return env
end

describe("agent_environment", function()
  local warnings, original_notify

  before_each(function()
    AgentEnvironment._reset_warnings()
    warnings = {}
    original_notify = vim.notify
    vim.notify = function(message)
      table.insert(warnings, message)
    end
  end)

  after_each(function()
    vim.notify = original_notify
  end)

  it("leaves the environment untouched when nothing is declared", function()
    assert.same({ PATH = "/usr/bin" }, apply())
    assert.same({ PATH = "/usr/bin" }, apply({}, {}))
  end)

  it("merges config values, stringifying numbers", function()
    local env = apply({ CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = 20, BASH_MAX_OUTPUT_LENGTH = "10000" })
    assert.equals("20", env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)
    assert.equals("10000", env.BASH_MAX_OUTPUT_LENGTH)
  end)

  it("lets the chat's frontmatter win over the config", function()
    -- The narrower scope wins, the same way frontmatter `model:` overrides `default_model`.
    local env = apply({ BASH_MAX_OUTPUT_LENGTH = "10000" }, { "BASH_MAX_OUTPUT_LENGTH=2000" })
    assert.equals("2000", env.BASH_MAX_OUTPUT_LENGTH)
  end)

  it("reads a frontmatter entry written as a bare string", function()
    -- The parser returns a string rather than a list for a hand-written `env: KEY=VALUE`.
    assert.equals("haiku", apply(nil, "CLAUDE_CODE_SUBAGENT_MODEL=haiku").CLAUDE_CODE_SUBAGENT_MODEL)
  end)

  it("ignores a frontmatter entry that is not KEY=VALUE", function()
    local env = apply(nil, { "BASH_MAX_OUTPUT_LENGTH", "MAX_THINKING_TOKENS=4096" })
    assert.is_nil(env.BASH_MAX_OUTPUT_LENGTH)
    assert.equals("4096", env.MAX_THINKING_TOKENS)
    assert.equals(1, #warnings)
  end)

  it("refuses the variables vibing.nvim owns", function()
    -- These carry the RPC port, the handle ID and the nested-invocation escape. A config value
    -- writing one would break the hook round trip that the permission gate and the diff baseline
    -- both ride on.
    local env = apply({ CLAUDECODE = "1", VIBING_NVIM_RPC_PORT = "1234", VIBING_HANDLE_ID = "x" })
    assert.is_nil(env.CLAUDECODE)
    assert.is_nil(env.VIBING_NVIM_RPC_PORT)
    assert.is_nil(env.VIBING_HANDLE_ID)
    assert.equals(3, #warnings)
  end)

  it("refuses a reserved key from frontmatter too", function()
    assert.is_nil(apply(nil, { "VIBING_NVIM_CONTEXT=false" }).VIBING_NVIM_CONTEXT)
    assert.equals(1, #warnings)
  end)

  it("ignores a value with no obvious spelling", function()
    local env = apply({ SOME_FLAG = true, OTHER = { 1 } })
    assert.is_nil(env.SOME_FLAG)
    assert.is_nil(env.OTHER)
    assert.equals(2, #warnings)
  end)

  it("warns once per key rather than once per turn", function()
    for _ = 1, 3 do
      apply({ CLAUDECODE = "1" })
    end
    assert.equals(1, #warnings)
  end)

  it("passes nothing to a lightweight call", function()
    -- No tools and no resumed session, so autocompaction, Bash output length and the subagent
    -- model have nothing to act on.
    local env =
      apply({ BASH_MAX_OUTPUT_LENGTH = "10000" }, { "MAX_THINKING_TOKENS=4096" }, { lightweight = true })
    assert.same({ PATH = "/usr/bin" }, env)
  end)
end)
