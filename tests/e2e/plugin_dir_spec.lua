-- E2E: a plugin dropped into `.vibing/plugins/` reaches the model.
--
-- The unit specs cover the two halves separately: plugin_dirs_spec proves the directory is
-- resolved, cli_command_builder_spec proves `--plugin-dir` lands in the argv. Neither can show
-- that the CLI then actually loads it, and that is the part with no error path — a `--plugin-dir`
-- the CLI declines to use is ignored in silence (exit 0, no warning), so a mistake here looks
-- exactly like everything working.
local helper = require("vibing.testing.e2e_helper")

-- tests/e2e is swept by `test:lua` too, and this spec sends a real request to the CLI.
-- Only `test:e2e` sets VIBING_E2E=1; everything else skips rather than quietly spending tokens.
if not helper.should_run() then
  return
end

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  -- A single short turn, but the plugin's skills are loaded before the first token.
  ASSISTANT_RESPONSE = 60000,
}

-- The marker has to be something the model cannot produce from the prompt alone, or the spec
-- passes without the skill ever having loaded.
local MARKER = "ZQXPLUMB"
local PLUGIN_NAME = "vibing-e2e-probe"
local SKILL_NAME = "marker-probe"

describe("E2E: .vibing/plugins is loaded via --plugin-dir", function()
  local nvim_instance
  local project_root

  before_each(function()
    -- A throwaway project directory, not the repository's own: a plugin written into the
    -- developer's real `.vibing/plugins/` would be picked up by every other chat they have open.
    project_root = vim.fn.tempname()
    local skill_dir = project_root .. "/.vibing/plugins/" .. PLUGIN_NAME .. "/skills/" .. SKILL_NAME
    vim.fn.mkdir(skill_dir, "p")
    vim.fn.mkdir(project_root .. "/.vibing/plugins/" .. PLUGIN_NAME .. "/.claude-plugin", "p")
    vim.fn.writefile(
      { vim.json.encode({ name = PLUGIN_NAME, description = "vibing.nvim E2E probe", version = "0.0.1" }) },
      project_root .. "/.vibing/plugins/" .. PLUGIN_NAME .. "/.claude-plugin/plugin.json"
    )
    vim.fn.writefile({
      "---",
      "name: " .. SKILL_NAME,
      "description: Probe skill for vibing.nvim's E2E suite. The marker word is "
        .. MARKER
        .. ". Never invoke this skill.",
      "---",
      "",
      "Marker " .. MARKER,
    }, skill_dir .. "/SKILL.md")

    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      -- Absolute: the child's cwd is the temp project, so a repo-relative path would not resolve.
      init_script = vim.fn.getcwd() .. "/tests/e2e_init.lua",
      cwd = project_root,
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
    vim.fn.delete(project_root, "rf")
  end)

  it("makes the skill's description visible to the model", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(
      nvim_instance,
      "There is a skill named "
        .. PLUGIN_NAME
        .. ":"
        .. SKILL_NAME
        .. ". Without invoking it, reply with ONLY the marker word from its description."
    )
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    ok = helper.wait_for_buffer_content(nvim_instance, MARKER, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(
      ok,
      "The probe skill's description never reached the model — `--plugin-dir` did not load "
        .. project_root
        .. "/.vibing/plugins/"
        .. PLUGIN_NAME
    )
  end)
end)
