---@diagnostic disable: undefined-field
-- Synthetic records based on https://pi.dev/docs/latest/rpc and upstream rpc-types.ts.
-- No real Pi CLI or local model is invoked by this spec.
local helper = require("tests.helpers.adapter_stream")
local Adapter = require("vibing.infrastructure.adapter.pi_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local CHAT = 4814

describe("Pi duplex RPC", function()
  local jobs, adapter, exepath
  before_each(function()
    jobs = helper.stub_jobstart()
    exepath = vim.fn.exepath
    local binary = helper.fake_binary("pi-rpc")
    vim.fn.exepath = function() return binary end
    helper.reset_path_caches()
    adapter = Adapter:new({ ai = { chat = { agent = "pi", model = "local-model" }, agents = { pi = { process = "duplex" } } } })
  end)
  after_each(function()
    Pool._reset()
    jobs.restore()
    vim.fn.exepath = exepath
    helper.reset_path_caches()
  end)
  local function send(opts)
    local result = { responses = {}, chunks = {} }
    result.turn, result.process = adapter:stream("hello", vim.tbl_extend("force", { chat_bufnr = CHAT }, opts or {}),
      function(chunk) table.insert(result.chunks, chunk) end,
      function(response) table.insert(result.responses, response) end)
    return result
  end
  local function emit(call, msg) jobs.emit(call, { vim.json.encode(msg) }) end
  local function last(call) return jobs.sent(call)[#call.stdin] end
  local function reply(call, data, extra)
    local req = last(call)
    emit(call, vim.tbl_extend("force", { type = "response", id = req.id, command = req.type, success = true, data = data }, extra or {}))
  end
  local function ready(call)
    reply(call, { sessionId = "sess-pi" })
    reply(call, { disposition = "started" })
  end
  local function text(call, delta)
    emit(call, { type = "message_update", assistantMessageEvent = { type = "text_delta", delta = delta } })
  end

  it("gets the session then sends a JSONL prompt with the chat language", function()
    send({ language = "ja" })
    local call = jobs.only_call()
    assert.equals("get_state", last(call).type)
    reply(call, { sessionId = "sess-pi" })
    local prompt = last(call)
    assert.equals("prompt", prompt.type)
    assert.is_truthy(prompt.message:find("Always respond in Japanese (ja).", 1, true))
  end)

  it("reuses one process and waits for settled after low-level tool turns", function()
    local first = send()
    local call = jobs.only_call()
    ready(call)
    text(call, "one")
    emit(call, { type = "turn_end" })
    assert.equals(0, #first.responses)
    emit(call, { type = "agent_settled" })
    assert.equals("one", first.responses[1].content)
    local second = send({ _session_id = "sess-pi" })
    assert.equals(first.process, second.process)
    assert.equals(1, #jobs.calls)
    assert.equals("prompt", last(call).type)
    reply(call, { disposition = "started" })
    text(call, "two")
    emit(call, { type = "agent_settled" })
    assert.equals("two", second.responses[1].content)
  end)

  it("ignores foreign replies and events before prompt acceptance", function()
    local result = send()
    local call = jobs.only_call()
    emit(call, { type = "response", id = "foreign", command = "get_state", success = true, data = { sessionId = "other" } })
    emit(call, { type = "agent_settled" })
    assert.equals(0, #result.responses)
    assert.equals("get_state", last(call).type)
  end)

  it("reports rejected commands and terminal provider failures", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, nil, { success = false, error = "invalid model" })
    assert.is_truthy(result.responses[1].error:find("invalid model", 1, true))
    local next_result = send()
    call = jobs.calls[#jobs.calls]
    ready(call)
    emit(call, { type = "message_end", message = { role = "assistant", stopReason = "error", errorMessage = "provider down" } })
    emit(call, { type = "agent_settled" })
    assert.equals("provider down", next_result.responses[1].error)
  end)

  it("cancels with abort and serves the next prompt on the same session", function()
    local first = send()
    local call = jobs.only_call()
    ready(call)
    adapter:stop_turn(first.process)
    local abort = last(call)
    assert.equals("abort", abort.type)
    emit(call, { type = "agent_settled" })
    assert.is_true(first.responses[1]._cancelled)
    local second = send()
    assert.equals(first.process, second.process)
    -- An abort reply can arrive after the next turn starts. Its failure must not kill that turn.
    emit(call, { type = "response", id = abort.id, command = "abort", success = false, error = "late abort" })
    reply(call, { disposition = "started" })
    text(call, "recovered")
    emit(call, { type = "agent_settled" })
    assert.equals("recovered", second.responses[1].content)
  end)

  it("finishes handled prompts without waiting for a run that will never start", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, { sessionId = "sess-pi" })
    reply(call, { disposition = "handled" })
    assert.equals(1, #result.responses)
    assert.is_nil(result.responses[1].error)
  end)

  it("declines extension dialogs explicitly instead of leaving Pi blocked", function()
    send()
    local call = jobs.only_call()
    ready(call)
    emit(call, { type = "extension_ui_request", id = "dialog-1", method = "confirm", title = "Confirm" })
    assert.same({ type = "extension_ui_response", id = "dialog-1", cancelled = true }, last(call))
  end)

  it("cancels startup without sending a prompt after abort", function()
    local result = send()
    local call = jobs.only_call()
    local state_request = last(call)
    adapter:stop_turn(result.process)
    emit(call, { type = "response", id = state_request.id, command = "get_state", success = true, data = { sessionId = "sess-pi" } })
    assert.equals("abort", last(call).type)
    assert.is_true(result.responses[1]._cancelled)
  end)

  it("rejects a state reply without a session id", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    assert.is_truthy(result.responses[1].error:find("no session id", 1, true))
  end)

  it("passes resume and fork through Pi's session flags", function()
    send({ _session_id = "saved-session", _is_fork = true })
    local call = jobs.only_call()
    assert.is_true(vim.tbl_contains(call.argv, "--fork"))
    assert.is_true(vim.tbl_contains(call.argv, "saved-session"))
  end)
end)
