-- Real Codex turns prove that model and effort changes keep the app-server alive (#867).
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local RESPONSE_MS = 60000

local function chat_value(instance, key, value)
  return vim.fn.rpcrequest(
    instance.job_id,
    "nvim_exec_lua",
    [[return require("vibing.presentation.chat.view")._current_buffer:update_frontmatter(...)]],
    { key, value }
  )
end

local function process_id(instance)
  return vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", [[
    local chat = require("vibing.presentation.chat.view")._current_buffer
    local record = require("vibing.infrastructure.adapter.modules.duplex_pool").get(chat.buf)
    return record and record.process_id or nil
  ]], {})
end

local function send(instance, count)
  helper.send_keys(instance, "GiReply exactly OK. Do not use tools.<Esc><CR>")
  local ok, reason = helper.wait_for_completed_turn(instance, count, RESPONSE_MS)
  assert.is_true(ok, reason or "Codex should complete the turn")
end

describe("E2E: Codex duplex model and effort changes", function()
  local instance

  before_each(function()
    instance = helper.spawn_backend_instance("codex")
  end)

  after_each(function()
    helper.cleanup_instance(instance)
  end)

  it("answers after a change and a return to defaults on one app-server", function()
    helper.send_keys(instance, ":VibingChat<CR>")
    assert.is_true(helper.wait_for_buffer_name(instance, "%.md$", 5000))
    assert.is_true(chat_value(instance, "process", "duplex"))
    assert.is_true(chat_value(instance, "model", "gpt-6-luna"))
    assert.is_true(chat_value(instance, "effort", "low"))
    local ready, reason = helper.wait_for_input_ready(instance, 15000)
    assert.is_true(ready, reason)

    send(instance, 1)
    local first = process_id(instance)
    assert.is_string(first)

    assert.is_true(chat_value(instance, "model", "gpt-6-sol"))
    assert.is_true(chat_value(instance, "effort", "high"))
    send(instance, 2)
    assert.equals(first, process_id(instance), "changing model and effort respawned Codex")

    assert.is_true(chat_value(instance, "model", "default"))
    assert.is_true(chat_value(instance, "effort", "default"))
    send(instance, 3)
    assert.equals(first, process_id(instance), "restoring defaults respawned Codex")
  end)
end)
