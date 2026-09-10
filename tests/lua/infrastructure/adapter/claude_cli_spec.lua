---@diagnostic disable: undefined-field
--- Covers the parts of the child environment only `claude_cli` decides: whether the CLI computes
--- its own git status block, and the variables the user declared through `agent.env` / the chat's
--- `env:` frontmatter.
---
--- They are environment assertions rather than argv ones because the CLI has no flag for either,
--- and they belong here rather than in `stream_options_spec` because no other backend reads them.
--- What the first protects is a cache property, so nothing downstream fails loudly when it
--- lapses -- the turns simply cost more.

local helper = require("tests.helpers.adapter_stream")
local claude = require("vibing.infrastructure.adapter.claude_cli")
local AgentEnvironment = require("vibing.infrastructure.adapter.modules.agent_environment")

local CONFIG = { agent = { default_model = "sonnet" } }
local VAR = "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS"

describe("claude_cli environment", function()
  local system, ambient

  before_each(function()
    system = helper.stub_system()
    -- The adapter reads the real process environment, so a developer who exports this variable
    -- would otherwise be asserted against instead of the code -- and "0" is exactly the value the
    -- feature documents as their escape hatch. Saved rather than dropped, so the suite leaves the
    -- process as it found it.
    ambient = vim.env[VAR]
    vim.env[VAR] = nil
  end)

  after_each(function()
    system.restore()
    vim.env[VAR] = ambient
  end)

  --- @param agent table? overrides merged into CONFIG.agent
  local function env_for(agent, opts)
    local config = { agent = vim.tbl_extend("force", CONFIG.agent, agent or {}) }
    helper.run_stream(claude:new(config), opts)
    return system.only_call().opts.env
  end

  describe("git instructions", function()
    it("disables the block by default", function()
      assert.equals("1", env_for().CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS)
    end)

    it("disables it on lightweight calls too", function()
      -- `--setting-sources ""` does not reach this: the block comes from the CLI's own startup, not
      -- from project settings, so a title generation would otherwise carry a per-turn prefix as well.
      assert.equals("1", env_for(nil, { lightweight = true }).CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS)
    end)

    it("forces the block back on when git_instructions is set", function()
      -- "0", not unset: unset falls through to `includeGitInstructions` in the user's settings.json,
      -- so a user who has that key set to false would ask for the block and not get it.
      assert.equals("0", env_for({ git_instructions = true }).CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS)
    end)

    it("does not overwrite a value the user set", function()
      -- "0" is the CLI's own way of forcing the block back on, so overwriting it would take away
      -- the escape hatch rather than merely duplicating the setting.
      vim.env[VAR] = "0"
      assert.equals("0", env_for().CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS)
    end)

    it("yields to a value declared through agent.env", function()
      -- `agent.env` is applied first and this default only fills a gap, so the more specific
      -- statement wins -- the same way an exported variable does.
      assert.equals(
        "0",
        env_for({ env = { CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS = "0" } }).CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS
      )
    end)
  end)

  describe("agent.env", function()
    before_each(function()
      -- Module-level and therefore process-wide: another spec file having already warned about a
      -- key would otherwise silence the assertion below.
      AgentEnvironment._reset_warnings()
    end)

    --- `env_for`'s `only_call` allows one spawn per test; this one compares two.
    local function next_env(agent, opts)
      local config = { agent = vim.tbl_extend("force", CONFIG.agent, agent or {}) }
      helper.run_stream(claude:new(config), opts)
      local env = system.calls[#system.calls].opts.env
      -- Regenerated per stream by design (it keys the hook back to this turn), so it is the one
      -- key two spawns are expected to differ on.
      env.VIBING_HANDLE_ID = nil
      return env
    end

    it("puts declared variables in the spawn environment", function()
      local env =
        env_for({ env = { CLAUDE_AUTOCOMPACT_PCT_OVERRIDE = 20, BASH_MAX_OUTPUT_LENGTH = "10000" } })
      assert.equals("20", env.CLAUDE_AUTOCOMPACT_PCT_OVERRIDE)
      assert.equals("10000", env.BASH_MAX_OUTPUT_LENGTH)
    end)

    it("lets the chat's frontmatter override the config", function()
      local env = env_for({ env = { CLAUDE_CODE_SUBAGENT_MODEL = "sonnet" } }, {
        env = { "CLAUDE_CODE_SUBAGENT_MODEL=haiku" },
      })
      assert.equals("haiku", env.CLAUDE_CODE_SUBAGENT_MODEL)
    end)

    it("changes nothing when unset", function()
      -- The whole environment, not one key: the feature has to be invisible to a user who never
      -- set it, since every variable it can carry changes what the turn costs.
      assert.same(next_env(), next_env({ env = {} }))
    end)

    it("cannot take over the variables that bind the child to this Neovim", function()
      local env = env_for({
        env = { VIBING_NVIM_RPC_PORT = "1234", VIBING_HANDLE_ID = "spoofed", CLAUDECODE = "1" },
      })
      -- 9999 is what the helper stubs the RPC server to report.
      assert.equals("9999", env.VIBING_NVIM_RPC_PORT)
      assert.is_not.equals("spoofed", env.VIBING_HANDLE_ID)
      assert.is_nil(env.CLAUDECODE)
    end)

    it("does not reach a lightweight call", function()
      local env = env_for({ env = { BASH_MAX_OUTPUT_LENGTH = "10000" } }, { lightweight = true })
      assert.is_nil(env.BASH_MAX_OUTPUT_LENGTH)
    end)
  end)
end)
