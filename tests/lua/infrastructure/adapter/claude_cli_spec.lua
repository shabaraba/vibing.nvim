---@diagnostic disable: undefined-field
--- Covers the part of the child environment only `claude_cli` decides: whether the CLI computes
--- its own git status block.
---
--- It is an environment assertion rather than an argv one because the CLI has no flag for it, and
--- it belongs here rather than in `stream_options_spec` because no other backend reads the
--- variable. What it protects is a cache property, so nothing downstream fails loudly when it
--- lapses -- the turns simply cost more.

local helper = require("tests.helpers.adapter_stream")
local claude = require("vibing.infrastructure.adapter.claude_cli")

local CONFIG = { agent = { default_model = "sonnet" } }
local VAR = "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS"

describe("claude_cli git instructions", function()
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
end)
