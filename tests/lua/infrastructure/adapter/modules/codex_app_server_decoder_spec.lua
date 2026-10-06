local Decoder = require("vibing.infrastructure.adapter.decoders.codex_app_server")
describe("Codex app-server decoder", function()
  local state
  before_each(function()
    state = {}
  end)
  local function decode(method, params)
    return Decoder.decode({ method = method, params = params }, state)
  end
  it("uses the exec tool contract for command starts and completions", function()
    local item = { id = "shell", type = "commandExecution", command = "ls", aggregatedOutput = "files" }
    local started = decode("item/started", { item = item })
    assert.equals("tool_start", started[1].kind)
    assert.equals("Bash", started[1].name)
    assert.equals("ls", started[1].input.command)
    local done = decode("item/completed", { item = item })
    assert.equals("tool_end", done[1].kind)
    assert.equals("files", done[1].result)
  end)
  it("maps structured file-change kinds and paths", function()
    local events = decode("item/completed", {
      item = {
        id = "edit",
        type = "fileChange",
        changes = {
          { path = "main.lua", kind = { type = "update" } },
        },
      },
    })
    assert.same({ "main.lua" }, events[1].input.file_paths)
    assert.equals("modified main.lua", events[2].result)
  end)
  it("maps thread totals to cumulative token usage", function()
    local events = decode("thread/tokenUsage/updated", {
      tokenUsage = {
        total = {
          inputTokens = 100,
          cachedInputTokens = 90,
          outputTokens = 12,
          reasoningOutputTokens = 5,
        },
      },
    })
    assert.equals("usage", events[1].kind)
    assert.is_true(require("vibing.core.utils.token_usage").is_cumulative(events[1].accumulator))
  end)
  it("renders message text when the server only emits a completed item", function()
    local events = decode("item/completed", { item = { id = "msg", type = "agentMessage", text = "answer" } })
    assert.equals("answer", events[1].delta)
  end)
  -- A body arrives twice -- as deltas while it is produced, and whole on `item/completed` -- so
  -- the completion must re-emit only what never streamed. Rendering both shows the block twice;
  -- rendering neither loses a short answer that produced no delta at all.
  describe("a body that arrives both as deltas and whole", function()
    it("does not render a streamed message a second time on completion", function()
      assert.equals("ans", decode("item/agentMessage/delta", { itemId = "msg", delta = "ans" })[1].delta)
      assert.same({}, decode("item/completed", { item = { id = "msg", type = "agentMessage", text = "answer" } }))
    end)

    it("does not render streamed reasoning a second time on completion", function()
      assert.equals("why", decode("item/reasoning/summaryTextDelta", { itemId = "r1", delta = "why" })[1].delta)
      assert.same({}, decode("item/completed", { item = { id = "r1", type = "reasoning", text = "why not" } }))
    end)

    it("renders reasoning that never streamed, which is how a resumed thread replays it", function()
      local events = decode("item/completed", { item = { id = "r2", type = "reasoning", text = "thought" } })
      assert.same({ { kind = "thinking", delta = "thought" } }, events)
    end)

    it("renders an empty agent message but not an empty reasoning body", function()
      -- The one way the two differ. An agent message is the whole answer, so the renderer wants
      -- the block opened even when it is empty; an empty reasoning body is nothing to show.
      assert.equals("", decode("item/completed", { item = { id = "m2", type = "agentMessage" } })[1].delta)
      assert.same({}, decode("item/completed", { item = { id = "r3", type = "reasoning", text = "" } }))
    end)

    it("tracks each item separately, so one completing does not un-mark another", function()
      decode("item/agentMessage/delta", { itemId = "a", delta = "x" })
      decode("item/reasoning/textDelta", { itemId = "b", delta = "y" })
      assert.same({}, decode("item/completed", { item = { id = "a", type = "agentMessage", text = "x" } }))
      assert.same({}, decode("item/completed", { item = { id = "b", type = "reasoning", text = "y" } }))
    end)

    it("forgets an item once it has completed, so the mark cannot outlive the turn", function()
      -- The table is reached per stdout line for the whole life of a resident process. An entry
      -- that is never removed is one the per-turn reset is the only thing standing between and
      -- unbounded growth.
      decode("item/agentMessage/delta", { itemId = "once", delta = "x" })
      decode("item/completed", { item = { id = "once", type = "agentMessage", text = "x" } })
      assert.same({}, state.streamed_items)
    end)
  end)

  it("keeps the measured hook-trust bypass gap explicit", function()
    local path = vim.fn.getcwd() .. "/tests/fixtures/streams/codex-app-server/hook_trust_probe.json"
    local probe = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    assert.equals("untrusted", probe.session_flag_hooks[1].trustStatus)
  end)
end)
