-- A background subagent finishing on a resident `claude` process reaches the chat as a turn.
--
-- `duplex_stream_spec.lua` proves the holding and replaying against lines the spec writes itself.
-- Whether the real CLI opens its own turn after `task_notification`, and whether the chat then shows
-- a `## Notice` and a second `## Assistant` without anyone typing, is only learnt by running it.
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 5000,
  INPUT_READY = 15000,
  -- The launching turn, then the subagent and the CLI's own answer to its completion.
  LAUNCH = 60000,
  CLI_TURN = 90000,
}

--- @param instance table
--- @param text string
local function send_turn(instance, text)
  helper.send_keys(instance, "G")
  helper.send_keys(instance, "i")
  helper.send_keys(instance, text)
  helper.send_keys(instance, "<Esc>")
  helper.send_keys(instance, "<CR>")
end

describe("E2E: a turn the CLI starts by itself on a resident process", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("claude")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("shows a background subagent's completion and the CLI's answer to it as a new turn", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY))

    vim.fn.rpcrequest(
      nvim_instance.job_id,
      "nvim_exec_lua",
      [[
        local chat = require("vibing.presentation.chat.view")._current_buffer
        chat:update_frontmatter("process", "duplex")
        chat:update_frontmatter("model", "haiku")
      ]],
      {}
    )
    local ok, reason = helper.wait_for_input_ready(nvim_instance, TIMEOUTS.INPUT_READY)
    assert.is_true(ok, reason)

    send_turn(
      nvim_instance,
      "Use the Agent tool with run_in_background set to true, subagent_type general-purpose, "
        .. 'description "pong probe" and prompt "Reply with the word PONG and nothing else." '
        .. 'Then reply with exactly "LAUNCHED" and end your turn without waiting.'
    )
    ok, reason = helper.wait_for_completed_turn(nvim_instance, 1, TIMEOUTS.LAUNCH)
    assert.is_true(ok, reason or "the launching turn should complete")

    ok, reason = helper.wait_for_completed_turn(nvim_instance, 2, TIMEOUTS.CLI_TURN)
    assert.is_true(ok, reason or "the CLI's own turn should reach the chat as a second completed turn")

    local text = table.concat(vim.fn.rpcrequest(nvim_instance.job_id, "nvim_buf_get_lines", 0, 0, -1, false), "\n")
    assert.is_truthy(text:find("## Notice <!--", 1, true), "no Notice announced the CLI's turn:\n" .. text)
    assert.is_truthy(text:find("Subagent finished: pong probe", 1, true), "the completion was not shown:\n" .. text)
  end)
end)
