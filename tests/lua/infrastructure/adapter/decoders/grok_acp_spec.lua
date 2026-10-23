---@diagnostic disable: undefined-field
local Decoder = require("vibing.infrastructure.adapter.decoders.grok_acp")

describe("decoders.grok_acp", function()
  --- Every captured frame is the same envelope around one `update` object, so the payloads below
  --- are the JSON as grok 1.0.50 emitted it and only the inner object varies.
  --- @param state table
  --- @param update_json string the `params.update` object, verbatim
  --- @return Vibing.CanonicalEvent[]
  local function decode(state, update_json)
    Decoder.decode({ method = "vibing/promptStarted" }, state)
    local frame = string.format(
      '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"01a1","update":%s}}',
      update_json
    )
    return Decoder.decode(vim.json.decode(frame), state)
  end

  -- The single most important assertion in this file. A turn ends on the `session/prompt` JSON-RPC
  -- reply, which names the prompt it answers; `turn_completed` carries only a `prompt_id` and
  -- arrives for subagent turns too, so consuming it ends the user's turn on work nobody asked for.
  it("does not end the turn on turn_completed", function()
    assert.same(
      {},
      decode({}, '{"sessionUpdate":"turn_completed","prompt_id":"d9cd1fc4","stop_reason":"end_turn","elapsed_ms":16}')
    )
  end)

  it("streams agent text and reasoning, each proving the CLI alive", function()
    assert.same(
      { { kind = "first_response" }, { kind = "text", delta = "`" } },
      decode({}, '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"`"}}')
    )
    assert.same(
      { { kind = "first_response" }, { kind = "thinking", delta = 'Writing "hi" to deny.txt.' } },
      decode(
        {},
        '{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"Writing \\"hi\\" to deny.txt."}}'
      )
    )
  end)

  -- grok sends the vendor method for `response_completed`, `model_changed` and `hook_annotation`
  -- and the standard one for the chunks and the tool calls; the envelope is identical. Reading only
  -- `session/update` left the usage, the model and the hook's refusal notice unreachable -- a turn
  -- rendered its prose and its tool calls and reported no tokens at all.
  it("reads an update off the vendor notification method too", function()
    local state = {}
    Decoder.decode({ method = "vibing/promptStarted" }, state)
    local events = Decoder.decode(
      vim.json.decode(
        '{"jsonrpc":"2.0","method":"_x.ai/session_notification","params":{"sessionId":"s",'
          .. '"update":{"sessionUpdate":"response_completed","usage":{"input_tokens":7}}}}'
      ),
      state
    )
    assert.same({ { kind = "usage", record = { input_tokens = 7 } } }, events)
  end)

  describe("tool calls", function()
    local TOOL_CALL = '{"sessionUpdate":"tool_call","toolCallId":"call-738d-0","title":"write",'
      .. '"rawInput":{"file_path":"/tmp/x/deny.txt","content":"hi\\n"},'
      .. '"_meta":{"x.ai/tool":{"version":1,"name":"write","kind":"write","namespace":"opencode",'
      .. '"label":"Write","read_only":false}}}'

    it("opens the call under the native tool id, with its raw input", function()
      assert.same({
        { kind = "first_response" },
        {
          kind = "tool_start",
          id = "call-738d-0",
          name = "write",
          input = { file_path = "/tmp/x/deny.txt", content = "hi\n" },
        },
      }, decode({}, TOOL_CALL))
    end)

    -- `title` is prose for a human and becomes ``Write `/path` `` on the very next update, so a name
    -- taken from it matches no `grok_tool_vocabulary` entry and no permission rule.
    it("prefers _meta's native name over the prose title", function()
      local events = decode(
        {},
        '{"sessionUpdate":"tool_call","toolCallId":"call-738d-0","title":"Write `/tmp/x`",'
          .. '"rawInput":{},"_meta":{"x.ai/tool":{"name":"write","label":"Write"}}}'
      )
      assert.equals("write", events[2].name)
    end)

    -- Two different messages share this name, separated only by `status` being present: the
    -- enrichment that adds the title, the locations and the diff arrives mid-call, and reading it
    -- as terminal closes the tool call before it ran.
    it("ignores the mid-call enrichment that carries no status", function()
      assert.same(
        {},
        decode(
          {},
          '{"sessionUpdate":"tool_call_update","toolCallId":"call-738d-0","kind":"edit",'
            .. '"title":"Write `/tmp/x/deny.txt`",'
            .. '"content":[{"type":"diff","path":"/tmp/x/deny.txt","oldText":"","newText":"hi\\n"}],'
            .. '"locations":[{"path":"/tmp/x/deny.txt"}],'
            .. '"rawInput":{"variant":"Write","file_path":"/tmp/x/deny.txt","content":"hi\\n"}}'
        )
      )
    end)

    -- Measured from a live `run_terminal_command`: grok streams `in_progress` twice, once empty and
    -- once with the output so far. Reading "has a status" as terminal closed the call three times,
    -- the first before the command had produced anything.
    it("ignores the in_progress updates that stream a command's output", function()
      assert.same(
        {},
        decode(
          {},
          '{"sessionUpdate":"tool_call_update","toolCallId":"call-fca0-0","status":"in_progress",'
            .. '"content":[{"type":"content","content":{"type":"text","text":"hello\\n"}}],'
            .. '"rawOutput":{"type":"Bash","output":[]}}'
        )
      )
    end)

    it("closes the call on a failed status, with the refusal as its result", function()
      assert.same({
        {
          kind = "tool_end",
          id = "call-738d-0",
          result = "User rejected the execution for tool `write`",
          is_error = true,
        },
      }, decode(
        {},
        '{"sessionUpdate":"tool_call_update","toolCallId":"call-738d-0","status":"failed",'
          .. '"content":[{"type":"content","content":{"type":"text","text":'
          .. '"User rejected the execution for tool `write`"}}]}'
      ))
    end)

    -- A successful edit's only `content` block is the `diff`, which the per-request git snapshot
    -- already renders -- so what it has to say arrives in `rawOutput`, nested under the name of the
    -- variant that ran. Reading only the top level left every completed edit closing with nothing.
    it("takes a completed edit's prose from the nested EditsApplied", function()
      local events = decode(
        {},
        '{"sessionUpdate":"tool_call_update","toolCallId":"call-c595-1","status":"completed",'
          .. '"content":[{"type":"diff","path":"/tmp/x/allow.txt","oldText":"","newText":"hi\\n"}],'
          .. '"rawOutput":{"type":"SearchReplace","EditsApplied":{"tool_output_for_prompt":'
          .. '"The file /tmp/x/allow.txt has been created."}}}'
      )
      assert.same({
        {
          kind = "tool_end",
          id = "call-c595-1",
          result = "The file /tmp/x/allow.txt has been created.",
          is_error = false,
        },
      }, events)
    end)

    -- The other nested shape, and the one that proves the descent is not "unwrap `EditsApplied`":
    -- a successful MCP call sends `"content":null` and puts its whole reply under `output`.
    it("takes a completed MCP call's reply from the nested output", function()
      local events = decode(
        {},
        '{"sessionUpdate":"tool_call_update","toolCallId":"call-7","status":"completed",'
          .. '"content":null,"rawOutput":{"type":"MCP","tool_name":"nvim_get_info",'
          .. '"server_name":"vibing-nvim","output":{"OkayOutput":"{\\"bufnr\\": 23}"}}}'
      )
      assert.equals('{"bufnr": 23}', events[1].result)
    end)

    -- The one measured shape that states its prose at the top level, so the descent must not be
    -- unconditional: a failure envelope.
    it("reads a failure's message straight off rawOutput", function()
      local events = decode(
        {},
        '{"sessionUpdate":"tool_call_update","toolCallId":"call-9","status":"failed",'
          .. '"rawOutput":{"error":"connection refused"}}'
      )
      assert.equals("connection refused", events[1].result)
    end)
  end)

  -- Per response, not cumulative: the `_meta.usage` block on the `session/prompt` reply is the
  -- running total for the whole session and would double-count. The keys are already the ones
  -- `TokenUsage.record` reads, so the payload is passed through rather than translated.
  it("passes a response's usage through untranslated", function()
    assert.same({
      {
        kind = "usage",
        record = {
          input_tokens = 10948,
          output_tokens = 148,
          cache_read_input_tokens = 10240,
          cache_creation_input_tokens = 0,
          reasoning_tokens = 104,
        },
      },
    }, decode(
      {},
      '{"sessionUpdate":"response_completed","usage":{"input_tokens":10948,"output_tokens":148,'
        .. '"cache_read_input_tokens":10240,"cache_creation_input_tokens":0,"reasoning_tokens":104}}'
    ))
  end)

  -- The only place the CLI says out loud that a tool was refused. Without it a denied call looks
  -- to the user like a turn that simply did nothing.
  it("reports what a hook decided, in grok's own words", function()
    assert.same({
      { kind = "error", message = "`write` blocked by project/vibing-probe: projectdir probe deny" },
    }, decode(
      {},
      '{"sessionUpdate":"hook_annotation","message":"`write` blocked by project/vibing-probe: '
        .. 'projectdir probe deny","kind":"tool_outcome"}'
    ))
  end)

  -- grok mixes the two key conventions within one protocol; `model_id` is the snake_case half.
  it("carries a model change out as cli_info", function()
    assert.same(
      { { kind = "cli_info", model = "grok-4.7" } },
      decode({}, '{"sessionUpdate":"model_changed","model_id":"grok-4.7","reasoning_effort":"high"}')
    )
  end)

  it("counts the tools the command list announces", function()
    assert.same(
      { { kind = "cli_info", tools = 2 } },
      decode(
        {},
        '{"sessionUpdate":"available_commands_update","availableCommands":[],'
          .. '"_meta":{"tools":["run_terminal_command","read_file"]}}'
      )
    )
  end)

  it("is silent about an update it has no handler for", function()
    assert.same(
      {},
      decode({}, '{"sessionUpdate":"pending_interaction","tool_call_id":"call-738d-0","kind":"permission"}')
    )
    assert.same(
      {},
      decode({}, '{"sessionUpdate":"session_summary_generated","session_summary":"Call nvim_get_info MCP raw result"}')
    )
  end)

  -- The method decides, not the payload. The `update` below is a probe rather than a capture --
  -- grok sends no frame like it, which is why the guard has to be asserted instead of observed: a
  -- decoder that dispatched on `params.update` alone would answer the agent→client *requests* that
  -- share this transport.
  it("is silent about a method that is not a session update", function()
    assert.same(
      {},
      Decoder.decode({
        jsonrpc = "2.0",
        id = 0,
        method = "session/request_permission",
        params = {
          sessionId = "01a1",
          toolCall = { toolCallId = "call-738d-0" },
          update = { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "`" } },
        },
      }, {})
    )
  end)

  -- The id arrives in a `session/new` / `session/load` *reply* rather than in any notification, so
  -- `grok_duplex_protocol` synthesises this frame once the session is named.
  it("reports the synthesised session once, per decoder state", function()
    local state = {}
    local started = { method = "vibing/sessionStarted", params = { session_id = "x" } }

    assert.same({ { kind = "session", session_id = "x" } }, Decoder.decode(started, state))
    assert.same({}, Decoder.decode(started, state))
    -- Per state, not per module: `decoder_state` belongs to the process, and a second process has
    -- its own session to announce.
    assert.same({ { kind = "session", session_id = "x" } }, Decoder.decode(started, {}))
  end)

  it("reports a refused request as a non-fatal error", function()
    assert.same(
      { { kind = "error", message = "no" } },
      Decoder.decode({ method = "vibing/requestDenied", params = { message = "no" } }, {})
    )
  end)

  -- `session/load` re-emits stored `session/update`s while the new turn is already open. Painting
  -- them reprints the prior conversation into the new Assistant. The prompt this process is
  -- answering starts at `vibing/promptStarted`.
  describe("resume catch-up", function()
    local OLD = '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"old reply"}}'
    local THOUGHT = '{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"old thought"}}'
    local TOOL = '{"sessionUpdate":"tool_call","toolCallId":"call-old","title":"write",'
      .. '"rawInput":{},"_meta":{"x.ai/tool":{"name":"write"}}}'

    local function raw(state, update_json)
      local frame = string.format(
        '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"01a1","update":%s}}',
        update_json
      )
      return Decoder.decode(vim.json.decode(frame), state)
    end

    it("drops text, thinking and tool calls until the prompt is written", function()
      local state = {}
      assert.same({}, raw(state, OLD))
      assert.same({}, raw(state, THOUGHT))
      assert.same({}, raw(state, TOOL))
    end)

    it("still reports the session id during load", function()
      local state = {}
      assert.same(
        { { kind = "session", session_id = "x" } },
        Decoder.decode({ method = "vibing/sessionStarted", params = { session_id = "x" } }, state)
      )
      assert.same({}, raw(state, OLD))
    end)

    it("renders live updates after the prompt is written", function()
      local state = {}
      assert.same({}, raw(state, OLD))
      Decoder.decode({ method = "vibing/promptStarted" }, state)
      assert.same({ { kind = "first_response" }, { kind = "text", delta = "old reply" } }, raw(state, OLD))
    end)

    it("keeps the prompt open for later turns on the same process", function()
      local state = {}
      Decoder.decode({ method = "vibing/promptStarted" }, state)
      Decoder.decode({ method = "vibing/promptStarted" }, state)
      assert.same({ { kind = "first_response" }, { kind = "text", delta = "hi" } }, raw(
        state,
        '{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}'
      ))
    end)
  end)
end)
