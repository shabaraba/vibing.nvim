-- Two real turns on one resident `claude` process (#777).
--
-- This is the one thing the unit tests cannot say. `duplex_stream_spec.lua` stubs `jobstart`, so it
-- proves the bookkeeping -- one spawn, a fresh turn entry, the argv reuse key -- against a fake
-- process that answers whatever the spec feeds it. Whether a real `claude` accepts a prompt on
-- stdin, answers it, stays alive, and answers a second one is a fact about the CLI, and the only
-- way to learn it is to do it.
--
-- The observable is `ChatBuffer._current_process_id`, which `send_message` clears before every send
-- and sets again from whatever `stream()` returned. Two turns reporting the same value means the
-- second one did not spawn. The pool is asked as well: equal ids with no live record would mean the
-- process died and its id was reused, which is not the thing being claimed.
local helper = require("vibing.testing.e2e_helper")

if not helper.should_run() then
  return
end

local TIMEOUTS = {
  BUFFER_READY = 5000,
  -- What every other real-turn spec in this directory budgets. A green run returns as soon as the
  -- pattern matches, so this only decides how long a turn that hangs rather than erroring costs.
  -- Two of them, which is the whole point of the spec, so the file's worst case is ~155s against
  -- the 240s `test:e2e` allows per file (`tests/e2e-timeout-gate.test.mjs`).
  ASSISTANT_RESPONSE = 60000,
  -- The gap between "the turn answered" and "the buffer is ready for the next message". Short,
  -- because it is a render on the main loop rather than anything the CLI does.
  INPUT_READY = 15000,
}

--- Wait until there is an empty `## User` section to type into.
---
--- Every other spec in this directory sends exactly one turn, so none of them needed this and the
--- shared helper does not have it. A second turn does: `wait_for_assistant_turns` is satisfied by
--- the *header*, which `send_message` writes as soon as the response starts, while the new unsent
--- section is added later by `_handle_response`. Typing in that gap put the second prompt inside
--- the first turn's assistant section — the chat still looked plausible, and the run failed one
--- assertion later for a reason that had nothing to do with the transport.
---
--- `wait_for_response` rather than `wait_for_buffer_content` so a turn that died still aborts here
--- with its own error instead of timing out (`.claude/rules/self-testing.md`).
--- @param instance table
--- @return boolean ok, string? reason
local function wait_for_input_ready(instance, timeout)
  return helper.wait_for_response(instance, "## User <!%-%- unsent %-%->", timeout)
end

--- What the chat buffer currently records as the process running its turns.
--- @param instance table
--- @return string|nil
local function current_process_id(instance)
  local ok, id = pcall(
    vim.fn.rpcrequest,
    instance.job_id,
    "nvim_exec_lua",
    [[
      local view = require("vibing.presentation.chat.view")
      local chat = view._current_buffer
      return chat and chat._current_process_id or nil
    ]],
    {}
  )
  return ok and id ~= vim.NIL and id or nil
end

--- Whether the duplex pool still holds a live process for the chat, and which id it is.
--- @param instance table
--- @return string|nil
local function pooled_process_id(instance)
  local ok, id = pcall(
    vim.fn.rpcrequest,
    instance.job_id,
    "nvim_exec_lua",
    [[
      local view = require("vibing.presentation.chat.view")
      local chat = view._current_buffer
      if not chat then
        return nil
      end
      local record = require("vibing.infrastructure.adapter.modules.duplex_pool").get(chat.buf)
      return record and record.process_id or nil
    ]],
    {}
  )
  return ok and id ~= vim.NIL and id or nil
end

--- @param instance table
--- @param text string
local function send_turn(instance, text)
  helper.send_keys(instance, "G")
  helper.send_keys(instance, "i")
  helper.send_keys(instance, text)
  helper.send_keys(instance, "<Esc>")
  helper.send_keys(instance, "<CR>")
end

describe("E2E: a chat on the duplex transport keeps one CLI process", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_backend_instance("claude")
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("answers a second turn on the process that answered the first", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "chat buffer should be created")

    -- Through the chat's own frontmatter rather than `setup()`, because that is the per-chat entry
    -- point a user reaches for and the one that has to survive a round trip through the file.
    local written = vim.fn.rpcrequest(
      nvim_instance.job_id,
      "nvim_exec_lua",
      [[return require("vibing.presentation.chat.view")._current_buffer:update_frontmatter("process", "duplex")]],
      {}
    )
    assert.is_true(written, "process: duplex should be written to the chat's frontmatter")

    local reason
    ok, reason = wait_for_input_ready(nvim_instance, TIMEOUTS.INPUT_READY)
    assert.is_true(ok, reason or "the new chat should have an unsent section to type into")

    send_turn(nvim_instance, 'Reply with exactly the word "one" and nothing else.')
    ok, reason = helper.wait_for_assistant_turns(nvim_instance, 1, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "the first turn should answer without failing")

    local first_process = current_process_id(nvim_instance)
    assert.is_not_nil(first_process, "the chat should have recorded the process that ran turn 1")
    assert.equals(first_process, pooled_process_id(nvim_instance), "turn 1 did not leave a resident process")

    ok, reason = wait_for_input_ready(nvim_instance, TIMEOUTS.INPUT_READY)
    assert.is_true(ok, reason or "the chat should offer a new unsent section after the first turn")

    send_turn(nvim_instance, 'Reply with exactly the word "two" and nothing else.')
    ok, reason = helper.wait_for_assistant_turns(nvim_instance, 2, TIMEOUTS.ASSISTANT_RESPONSE)
    assert.is_true(ok, reason or "the second turn should answer without failing")

    local second_process = current_process_id(nvim_instance)
    assert.equals(first_process, second_process, "the second turn spawned a CLI process of its own")
    -- Not redundant with the line above: two turns could report one id and the process be gone,
    -- which is a resumed conversation rather than a resident process.
    assert.equals(first_process, pooled_process_id(nvim_instance), "the process did not survive its second turn")
  end)
end)
