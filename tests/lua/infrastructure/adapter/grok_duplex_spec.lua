---@diagnostic disable: undefined-field
--- The resident `grok agent stdio` transport, driven through the real adapter so the handshake
--- order, the turn boundary and the interrupt are exercised as a CLI would see them.

local helper = require("tests.helpers.adapter_stream")
local Adapter = require("vibing.infrastructure.adapter.grok_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")

local CHAT = 4711

describe("Grok duplex ACP agent", function()
  local jobs, adapter, exepath, executable

  before_each(function()
    jobs = helper.stub_jobstart()
    helper.reset_path_caches()
    exepath = vim.fn.exepath
    executable = vim.fn.executable
    vim.fn.exepath = function()
      return helper.fake_binary("duplex-grok")
    end
    -- Reported non-executable so the official-CLI sniff is skipped.
    vim.fn.executable = function(path)
      if path:find("duplex%-grok") then
        return 0
      end
      return executable(path)
    end
    adapter = Adapter:new({
      agent = { default_model = "grok-4.7", plugins = { self = false, project_dir = false } },
      backends = { grok = { process = "duplex" } },
    })
  end)

  after_each(function()
    Pool._reset()
    jobs.restore()
    vim.fn.exepath = exepath
    vim.fn.executable = executable
    helper.reset_path_caches()
  end)

  --- @param extra table|nil
  local function send(extra)
    local result = { responses = {}, chunks = {} }
    result.turn, result.process = adapter:stream(
      "hello",
      vim.tbl_extend("force", { chat_bufnr = CHAT, permissions_allow = {} }, extra or {}),
      function(text)
        table.insert(result.chunks, text)
      end,
      function(response)
        table.insert(result.responses, response)
      end
    )
    return result
  end

  local function emit(call, msg)
    jobs.emit(call, { vim.json.encode(msg) })
  end
  local function last(call)
    return jobs.sent(call)[#call.stdin]
  end
  local function reply(call, result)
    emit(call, { id = last(call).id, result = result })
  end

  --- Answer a specific request rather than whatever was written last.
  ---
  --- Needed because the agent is not the only thing that writes: a `session/cancel` notification
  --- carries no id at all, and a permission answer carries grok's. Replying to the last write
  --- would answer one of those and leave the prompt pending, which reads as a turn that never
  --- ended.
  local function reply_to(call, id, result)
    emit(call, { id = id, result = result })
  end

  --- Walk the handshake up to the point where a prompt has been written.
  --- @param call table
  --- @param session_result table|nil what `session/new` / `session/load` answers
  --- @return string|number prompt_id the id of the `session/prompt` left pending
  local function ready(call, session_result)
    assert.equals("initialize", last(call).method)
    reply(call, { protocolVersion = 1, agentCapabilities = {} })
    reply(call, session_result or { sessionId = "sess-1" })
    assert.equals("session/prompt", last(call).method)
    return last(call).id
  end

  it("handshakes initialize then session/new then session/prompt", function()
    send()
    local call = jobs.only_call()
    assert.equals("initialize", last(call).method)
    reply(call, { protocolVersion = 1 })

    local new_request = last(call)
    assert.equals("session/new", new_request.method)
    assert.is_not_nil(new_request.params.cwd)
    -- Required by the agent: omitting it is an `Invalid params` error naming the field.
    assert.is_table(new_request.params.mcpServers)
    reply(call, { sessionId = "sess-1" })

    local prompt_request = last(call)
    assert.equals("session/prompt", prompt_request.method)
    assert.equals("sess-1", prompt_request.params.sessionId)
    assert.equals("text", prompt_request.params.prompt[1].type)
  end)

  it("resumes with session/load, naming the session it was given", function()
    send({ _session_id = "sess-old" })
    local call = jobs.only_call()
    reply(call, { protocolVersion = 1 })
    local load_request = last(call)
    assert.equals("session/load", load_request.method)
    assert.equals("sess-old", load_request.params.sessionId)
  end)

  it("keeps the session id a load did not echo back", function()
    -- `session/load` answers with no `sessionId` of its own; the one we asked to resume is it.
    send({ _session_id = "sess-old" })
    local call = jobs.only_call()
    reply(call, { protocolVersion = 1 })
    reply(call, vim.empty_dict())
    assert.equals("session/prompt", last(call).method)
    assert.equals("sess-old", last(call).params.sessionId)
  end)

  it("puts the conventions on the first prompt and on no later one", function()
    -- `grok agent` has no `--rules`, so the instructions ride here. Repeating them every turn
    -- would churn the prompt cache for text that has not changed.
    local first = send()
    local call = jobs.only_call()
    ready(call)
    local first_text = last(call).params.prompt[1].text
    assert.is_not_nil(first_text:find(".vibing/worktrees/", 1, true))
    assert.is_not_nil(first_text:find("hello", 1, true))

    reply(call, { stopReason = "end_turn" })
    assert.equals(1, #first.responses)

    send()
    local second_text = last(call).params.prompt[1].text
    assert.equals("hello", second_text)
  end)

  it("ends the turn on the session/prompt reply, not on a turn_completed notification", function()
    -- The reply is correlated to its request by id. `turn_completed` also fires for turns grok ran
    -- for itself (a subagent), so consuming it would end the user's turn on work nobody asked for.
    local result = send()
    local call = jobs.only_call()
    ready(call)

    emit(call, {
      method = "session/update",
      params = { sessionId = "sess-1", update = { sessionUpdate = "turn_completed", prompt_id = "other", stop_reason = "end_turn" } },
    })
    assert.equals(0, #result.responses)

    reply(call, { stopReason = "end_turn" })
    assert.equals(1, #result.responses)
    assert.is_nil(result.responses[1].error)
  end)

  it("serves a second turn on the same process without handshaking again", function()
    local first = send()
    local call = jobs.only_call()
    ready(call)
    reply(call, { stopReason = "end_turn" })
    assert.equals(1, #first.responses)

    send()
    assert.equals(call, jobs.only_call())
    assert.equals("session/prompt", last(call).method)
  end)

  it("streams assistant text out of ACP session updates", function()
    local result = send()
    local call = jobs.only_call()
    ready(call)
    emit(call, {
      method = "session/update",
      params = { sessionId = "sess-1", update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "hi there" } } },
    })
    reply(call, { stopReason = "end_turn" })
    assert.is_not_nil(result.responses[1].content:find("hi there", 1, true))
  end)

  it("interrupts with session/cancel and retires the process afterwards", function()
    -- **The measured difference from codex, which keeps its process.** After a `session/cancel`
    -- grok answers the in-flight prompt in ~2ms, but a prompt sent 16ms later never gets a reply
    -- at all (65s, to the probe's own deadline) while one sent 8s later completes normally. So the
    -- reply is not proof the session will take another prompt, and the pool's reuse test would say
    -- yes exactly when it must not.
    local result = send()
    local call = jobs.only_call()
    local prompt_id = ready(call)

    assert.is_true(adapter:stop_turn(result.process))
    assert.equals("session/cancel", last(call).method)
    assert.equals("sess-1", last(call).params.sessionId)

    reply_to(call, prompt_id, { stopReason = "cancelled" })
    assert.equals("Cancelled", result.responses[1].error)
    assert.is_nil(Pool.get(CHAT))
  end)

  it("keeps the process when grok cancelled a turn for its own reasons", function()
    -- A rejected approval also ends a turn as `cancelled`, and that process *is* reusable: three
    -- prompts in a row over one rejection are what the approval probe recorded. So the retirement
    -- above is keyed on having sent the cancel, never on the stop reason.
    local result = send()
    local call = jobs.only_call()
    ready(call)

    reply(call, { stopReason = "cancelled" })
    assert.equals("Cancelled", result.responses[1].error)
    assert.is_not_nil(Pool.get(CHAT))
  end)

  it("answers grok's own permission request with the single-use option", function()
    local result = send()
    local call = jobs.only_call()
    local prompt_id = ready(call)

    emit(call, {
      id = 7,
      method = "session/request_permission",
      params = {
        sessionId = "sess-1",
        toolCall = { toolCallId = "call-1", title = "Write `/tmp/x`" },
        options = {
          { optionId = "allow-edits-session", kind = "allow_always" },
          { optionId = "allow-once", kind = "allow_once" },
          { optionId = "reject-once", kind = "reject_once" },
        },
      },
    })

    local answer = last(call)
    assert.equals(7, answer.id)
    -- `allow_once`, never `allow_always`: the session-wide option would retire grok's gate for
    -- every later call in the chat.
    assert.equals("allow-once", answer.result.outcome.optionId)
    assert.equals("selected", answer.result.outcome.outcome)

    reply_to(call, prompt_id, { stopReason = "end_turn" })
    assert.equals(1, #result.responses)
  end)

  it("fails the turn when the agent reports a JSON-RPC error", function()
    local result = send()
    local call = jobs.only_call()
    assert.equals("initialize", last(call).method)
    emit(call, { id = last(call).id, error = { message = "no auth" } })
    assert.is_not_nil(result.responses[1].error:find("no auth", 1, true))
  end)
end)
