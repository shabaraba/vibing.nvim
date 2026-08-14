local NonClaudeModel = require("vibing.infrastructure.adapter.modules.non_claude_model")

describe("non_claude_model", function()
  local CONFIG = { agent = { default_model = "gpt-5-codex", utility_model = "gpt-5-mini" } }

  it("uses default_model for an ordinary call", function()
    assert.equals("gpt-5-codex", NonClaudeModel.resolve({}, CONFIG))
  end)

  it("lets opts.model win over default_model", function()
    assert.equals("grok-4", NonClaudeModel.resolve({ model = "grok-4" }, CONFIG))
  end)

  it("uses utility_model for a lightweight call", function()
    assert.equals("gpt-5-mini", NonClaudeModel.resolve({ lightweight = true }, CONFIG))
  end)

  it("ignores opts.model for a lightweight call", function()
    -- The chat's own model is not the utility call's model; that is the whole point of the flag.
    assert.equals("gpt-5-mini", NonClaudeModel.resolve({ lightweight = true, model = "grok-4" }, CONFIG))
  end)

  it("drops Claude short names so the CLI applies its own default", function()
    for _, name in ipairs({ "sonnet", "opus", "haiku", "fable" }) do
      assert.is_nil(NonClaudeModel.resolve({ model = name }, CONFIG), name .. " should not be forwarded")
    end
  end)

  it("drops the sonnet default of utility_model rather than forwarding it", function()
    -- utility_model defaults to "sonnet", which none of these backends has.
    local config = { agent = { default_model = "gpt-5-codex", utility_model = "sonnet" } }
    assert.is_nil(NonClaudeModel.resolve({ lightweight = true }, config))
  end)

  it("returns nil when nothing is configured", function()
    assert.is_nil(NonClaudeModel.resolve({}, {}))
    assert.is_nil(NonClaudeModel.resolve({ lightweight = true }, {}))
  end)
end)

describe("every non-claude command builder honours utility_model", function()
  -- #537 was filed against codex, but copilot and grok carried a byte-identical resolve_model and
  -- the same bug. This pins that the shared helper actually reached all three.
  local BACKENDS = {
    { name = "codex", binary = "codex", module = "codex_command_builder" },
    { name = "copilot", binary = "copilot", module = "copilot_command_builder" },
    { name = "grok", binary = "grok", module = "grok_command_builder" },
  }

  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
  end)

  for _, backend in ipairs(BACKENDS) do
    it(backend.name .. " passes utility_model on a lightweight call", function()
      local builder = require("vibing.infrastructure.adapter.modules." .. backend.module)
      if builder._reset_path_cache then
        builder._reset_path_cache()
      end
      vim.fn.exepath = function(name)
        if name == backend.binary then
          return "/usr/local/bin/" .. backend.binary
        end
        return original_exepath(name)
      end

      local config = { agent = { default_model = "big-model", utility_model = "small-model" } }
      local cmd = builder.build("hi", { lightweight = true }, nil, config, nil)

      assert.is_true(vim.tbl_contains(cmd, "small-model"), backend.name .. " did not pass utility_model")
      assert.is_false(vim.tbl_contains(cmd, "big-model"), backend.name .. " passed default_model instead")

      if builder._reset_path_cache then
        builder._reset_path_cache()
      end
    end)
  end
end)
