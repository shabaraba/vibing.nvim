local helper = require("vibing.testing.e2e_helper")
if not helper.should_run() then
  return
end

local TIMEOUTS = { RECOVERY = 5000, RESPONSE = 5000 }
local fixture = vim.fn.getcwd() .. "/tests/fixtures/stalled-cli.mjs"

describe("E2E: recover a resident process stalled after partial output", function()
  local instance
  local function lua(code, args)
    return vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", code, args or {})
  end

  before_each(function()
    instance = helper.spawn_backend_instance("claude")
    helper.setup_child(instance, {
      ai = { agents = { claude = { process = "duplex" } } },
      automation = { stall = { timeout_sec = 0.2 } },
      integrations = { plugins = { self = false, project_dir = false } },
    })
    lua(
      [[
      local fixture = ...
      require("vibing.infrastructure.adapter.backends.claude").build = function()
        return { "node", fixture }
      end
      vim.cmd("VibingChat")
      local chat = require("vibing.presentation.chat.view")._current_buffer
      chat.update_filename_from_message = function() end
      _G.stall_chat = chat
    ]],
      { fixture }
    )
  end)

  after_each(function()
    helper.cleanup_instance(instance)
  end)

  it("shows an error, unlocks input, preserves the conversation and answers on a new process", function()
    lua([[
      require("vibing.presentation.chat.modules.programmatic_sender").send(stall_chat.buf, "STALL_FIXTURE")
    ]])
    assert.is_true(
      vim.wait(TIMEOUTS.RECOVERY, function()
        return lua([[return not stall_chat:is_responding() and stall_chat:get_stop_reason() == "error"]])
      end, 20),
      "the stalled turn should end as error, not remain responding"
    )
    local state = lua([[
      return {
        session = stall_chat:get_session_id(),
        text = table.concat(vim.api.nvim_buf_get_lines(stall_chat.buf, 0, -1, false), "\n"),
        pooled = require("vibing.infrastructure.adapter.modules.duplex_pool").get(stall_chat.buf) ~= nil,
        process = stall_chat._current_process_id,
      }
    ]])
    assert.equals("stall-fixture-session", state.session)
    assert.is_false(state.pooled)
    assert.is_not_nil(state.text:find("**Error:** No CLI activity", 1, true))
    assert.is_nil(state.text:find("Session has been reset", 1, true))
    lua([[
      require("vibing.presentation.chat.modules.programmatic_sender").send(stall_chat.buf, "continue")
    ]])
    assert.is_true(
      vim.wait(TIMEOUTS.RESPONSE, function()
        return lua([[return not stall_chat:is_responding() and stall_chat:get_stop_reason() ~= "error"]])
      end, 20),
      "a new turn should answer successfully"
    )
    assert.are_not.equals(state.process, lua([[return stall_chat._current_process_id]]))
    assert.equals("stall-fixture-session", lua([[return stall_chat:get_session_id()]]))
  end)

  it("delivers a queued message after retiring the stalled turn", function()
    local queued = lua([[
      local sender = require("vibing.infrastructure.rpc.handlers.message")
      sender.send_message({ bufnr = stall_chat.buf, message = "STALL_FIXTURE" })
      return sender.send_message({ bufnr = stall_chat.buf, message = "continue", queue_if_busy = true })
    ]])
    assert.is_true(queued.queued)
    assert.is_true(
      vim.wait(TIMEOUTS.RECOVERY, function()
        return lua([[
        local text = table.concat(vim.api.nvim_buf_get_lines(stall_chat.buf, 0, -1, false), "\n")
        local _, replies = text:gsub("fixture response", "")
        return not stall_chat:is_responding() and replies == 2
      ]])
      end, 20),
      "the queued turn should run after the watchdog frees the chat"
    )
    assert.equals("stall-fixture-session", lua([[return stall_chat:get_session_id()]]))
  end)
end)
