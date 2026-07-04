-- tests/e2e/vibing_workspace_spec.lua
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  COMMAND = 3000,
}

describe("E2E: vibing-workspace commands", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("lists no active workspaces in a fresh repository", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, "/vibing-workspace-list")
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    ok = helper.wait_for_buffer_content(nvim_instance, "No active workspaces", TIMEOUTS.COMMAND)
    assert.is_true(ok, "Workspace list should report no active workspaces")
  end)
end)
