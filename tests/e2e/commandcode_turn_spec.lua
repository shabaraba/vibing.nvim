local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 5000,
  ASSISTANT_RESPONSE = 120000,
}

describe("E2E: commandcode completes a turn through the shared adapter", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("commandcode")
    helper.setup_child(nvim_instance, {
      ai = {
        chat = {
          agent = "commandcode",
          model = vim.env.VIBING_COMMANDCODE_MODEL or "deepseek/deepseek-v4-flash",
        },
      },
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("answers, and the turn is not an error", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, 'Say "test"')
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    local reason
    ok, reason = helper.wait_for_completed_turn(nvim_instance, 1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "commandcode should answer without the turn failing")
  end)
end)
