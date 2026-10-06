local helper = require("tests.helpers.adapter_stream")
local Adapter = require("vibing.infrastructure.adapter.codex_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local Registry = require("vibing.infrastructure.adapter.modules.turn_registry")
local Native = require("vibing.infrastructure.rpc.pending_native_approvals")
local CHAT = 4243

describe("Codex duplex app-server", function()
  local jobs, adapter, exepath
  before_each(function()
    jobs = helper.stub_jobstart()
    helper.reset_path_caches()
    exepath = vim.fn.exepath
    vim.fn.exepath = function()
      return helper.fake_binary("duplex-codex")
    end
    adapter = Adapter:new({
      agent = { default_model = "gpt-6-sol", plugins = { self = false, project_dir = false } },
      backends = { codex = { process = "duplex", profile_file = false } },
    })
  end)
  after_each(function()
    Native._reset()
    Pool._reset()
    jobs.restore()
    vim.fn.exepath = exepath
    helper.reset_path_caches()
  end)
  local function send(extra)
    local result = { responses = {}, chunks = {} }
    result.turn, result.process = adapter:stream(
      "hello",
      vim.tbl_extend("force", {
        chat_bufnr = CHAT,
        permissions_allow = {},
      }, extra or {}),
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
  local function trusted_hook(call)
    assert.equals("hooks/list", last(call).method)
    reply(call, {
      data = {
        {
          hooks = {
            {
              eventName = "preToolUse",
              enabled = true,
              trustStatus = "trusted",
              source = "sessionFlags",
              command = require("vibing.infrastructure.hooks.codex_settings_generator").script_path(vim.fn.getcwd()),
            },
          },
        },
      },
    })
  end
  local function ready(call)
    assert.equals("initialize", last(call).method)
    reply(call, {})
    trusted_hook(call)
    assert.equals("thread/start", last(call).method)
    reply(call, { thread = { id = "thread-1" } })
    assert.equals("turn/start", last(call).method)
    assert.equals("gpt-6-sol", last(call).params.model)
    reply(call, { turn = { id = "turn-1" } })
  end
  local function note(call, method, params)
    emit(
      call,
      { method = method, params = vim.tbl_extend("force", { threadId = "thread-1", turnId = "turn-1" }, params or {}) }
    )
  end
  local function finish(call, status, id)
    emit(call, {
      method = "turn/completed",
      params = { threadId = "thread-1", turn = { id = id or "turn-1", status = status or "completed" } },
    })
  end

  it("starts app-server with hook overrides and never puts the prompt or exec flags in argv", function()
    send()
    local call = jobs.only_call()
    assert.is_true(vim.tbl_contains(call.argv, "app-server"))
    assert.is_false(vim.tbl_contains(call.argv, "exec"))
    assert.is_false(vim.tbl_contains(call.argv, "hello"))
    assert.is_true(vim.tbl_contains(call.argv, 'model="gpt-6-sol"'))
    assert.is_false(vim.tbl_contains(call.argv, "--dangerously-bypass-hook-trust"))
    local hook
    for _, arg in ipairs(call.argv) do
      if arg:match("^hooks.PreToolUse=") then
        hook = arg
      end
    end
    assert.is_string(hook)
  end)
  it("finishes two turns on one process and stores the thread session", function()
    local first = send()
    local call = jobs.only_call()
    ready(call)
    note(call, "item/agentMessage/delta", { itemId = "a1", delta = "answer" })
    note(call, "item/completed", { item = { id = "a1", type = "agentMessage", text = "answer" } })
    finish(call)
    assert.equals("answer", first.responses[1].content)
    emit(call, { method = "thread/started", params = { thread = { id = "child-thread" } } })
    assert.equals("thread-1", adapter:get_session_id(first.process))
    assert.is_nil(Registry.get(first.turn))
    local second = send({ _session_id = "thread-1" })
    assert.equals(first.process, second.process)
    assert.equals(1, #jobs.calls)
    assert.equals("turn/start", last(call).method)
    reply(call, { turn = { id = "turn-2" } })
    finish(call, "completed", "turn-2")
    assert.equals(1, #second.responses)
    assert.is_not_nil(Pool.get(CHAT))
  end)
  it("resumes a saved thread through RPC, not through argv", function()
    send({ _session_id = "saved-thread" })
    local call = jobs.only_call()
    reply(call, {})
    trusted_hook(call)
    assert.equals("thread/resume", last(call).method)
    assert.equals("saved-thread", last(call).params.threadId)
    assert.is_false(vim.tbl_contains(call.argv, "saved-thread"))
  end)
  it("queues early notifications until turn/start identifies this turn and rejects foreign completion", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    trusted_hook(call)
    reply(call, { thread = { id = "thread-1" } })
    note(call, "item/agentMessage/delta", { itemId = "a", delta = "early" })
    finish(call, "completed", "foreign-turn")
    reply(call, { turn = { id = "turn-1" } })
    assert.is_true(vim.wait(100, function()
      return table.concat(result.chunks) == "early"
    end))
    assert.equals(0, #result.responses)
    finish(call)
    assert.equals(1, #result.responses)
  end)
  it("interrupts only the active Codex turn and keeps its process", function()
    local result = send()
    local call = jobs.only_call()
    ready(call)
    local handled = adapter:stop_turn(result.process)
    assert.is_true(handled)
    assert.equals("turn/interrupt", last(call).method)
    assert.equals("turn-1", last(call).params.turnId)
    finish(call, "interrupted")
    assert.equals("Cancelled", result.responses[1].error)
    assert.is_not_nil(Pool.get(CHAT))
  end)
  it("reports failed terminal status as a failed response", function()
    local result = send()
    local call = jobs.only_call()
    ready(call)
    emit(call, {
      method = "turn/completed",
      params = {
        threadId = "thread-1",
        turn = {
          id = "turn-1",
          status = "failed",
          error = { message = "provider unavailable" },
        },
      },
    })
    assert.equals("provider unavailable", result.responses[1].error)
  end)
  it("refuses to start inference when the permission hook is absent or untrusted", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    reply(call, { data = {} })
    assert.matches("trusted PreToolUse hook", result.responses[1].error)
    assert.equals("hooks/list", last(call).method)
    assert.is_nil(Pool.get(CHAT))
  end)
  it("trusts only its session hook and verifies it before starting inference", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    local script = require("vibing.infrastructure.hooks.codex_settings_generator").script_path(vim.fn.getcwd())
    reply(call, { data = { { hooks = {
      { eventName = "preToolUse", enabled = true, trustStatus = "untrusted", source = "user",
        command = script, key = "other", currentHash = "sha256:other" },
      { eventName = "preToolUse", enabled = true, trustStatus = "untrusted", source = "sessionFlags",
        command = script, key = "session-key", currentHash = "sha256:expected" },
    } } } })
    assert.equals("config/batchWrite", last(call).method)
    local params = last(call).params
    assert.equals("hooks.state", params.edits[1].keyPath)
    assert.equals("upsert", params.edits[1].mergeStrategy)
    assert.same({ ["session-key"] = { trusted_hash = "sha256:expected" } }, params.edits[1].value)
    assert.is_true(params.reloadUserConfig)
    reply(call, {})
    assert.equals("hooks/list", last(call).method)
    assert.equals(0, #result.responses)
    trusted_hook(call)
    assert.equals("thread/start", last(call).method)
  end)
  it("fails closed if the trust write does not make its hook trusted", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    local script = require("vibing.infrastructure.hooks.codex_settings_generator").script_path(vim.fn.getcwd())
    local untrusted = { data = { { hooks = { {
      eventName = "preToolUse", enabled = true, trustStatus = "untrusted", source = "sessionFlags",
      command = script, key = "session-key", currentHash = "sha256:expected",
    } } } } }
    reply(call, untrusted)
    reply(call, {})
    reply(call, untrusted)
    assert.matches("trusted PreToolUse hook", result.responses[1].error)
    assert.is_nil(Pool.get(CHAT))
  end)
  it("never trusts an unrelated hook", function()
    local result = send()
    local call = jobs.only_call()
    reply(call, {})
    reply(call, { data = { { hooks = { {
      eventName = "preToolUse", enabled = true, trustStatus = "untrusted", source = "sessionFlags",
      command = "/tmp/other.sh", key = "other", currentHash = "sha256:other",
    } } } } })
    assert.matches("trusted PreToolUse hook", result.responses[1].error)
    assert.equals("hooks/list", last(call).method)
  end)
  it("surfaces initialization errors once and reclaims the bad process", function()
    local result = send()
    local call = jobs.only_call()
    emit(call, { id = last(call).id, error = { message = "unsupported initialize" } })
    assert.matches("unsupported initialize", result.responses[1].error)
    assert.is_nil(Pool.get(CHAT))
    jobs.flush_exits()
    assert.equals(1, #result.responses)
  end)
  describe("Codex's own approval requests", function()
    --- Everything a prompt was drawn with, in the order `on_approval_required` received it.
    local function asking()
      local drawn = {}
      return drawn,
        function(tool, input, options, request_id, waiting, kind)
          table.insert(drawn, {
            tool = tool,
            input = input,
            options = options,
            request_id = request_id,
            waiting = waiting,
            kind = kind,
          })
        end
    end

    it("asks the chat instead of refusing, and writes nothing until it is answered", function()
      local drawn, on_approval_required = asking()
      send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)
      local before = #call.stdin

      emit(call, {
        id = 88,
        method = "item/commandExecution/requestApproval",
        params = { command = "/bin/zsh -lc 'ls'", cwd = "/tmp", reason = "outside the sandbox", availableDecisions = { "accept", "cancel" } },
      })

      -- Nothing on the wire: the request is being held open, which is the whole feature.
      assert.equals(before, #call.stdin)
      assert.equals(1, #drawn)
      assert.equals("Codex command execution", drawn[1].tool)
      assert.equals("/bin/zsh -lc 'ls'", drawn[1].input.command)
      assert.is_true(vim.tbl_contains(drawn[1].input.details, "in /tmp"))
      assert.is_true(vim.tbl_contains(drawn[1].input.details, "outside the sandbox"))
      assert.is_true(drawn[1].waiting)
      -- The kind is what keeps the answer out of vibing's own permission lists.
      assert.equals("native", drawn[1].kind)
      assert.is_not_nil(Native.get(drawn[1].request_id))
    end)

    it("sends the human's decision back as the response to that very request", function()
      local drawn, on_approval_required = asking()
      send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)
      emit(call, { id = 88, method = "item/commandExecution/requestApproval", params = {} })

      assert.is_true(Native.resolve(drawn[1].request_id, "accept"))
      assert.equals(88, last(call).id)
      assert.equals("accept", last(call).result.decision)
    end)

    it("names the request by process as well as by Codex's id, which restarts at 0 per process", function()
      local drawn, on_approval_required = asking()
      local result = send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)
      emit(call, { id = 0, method = "item/commandExecution/requestApproval", params = {} })

      assert.is_truthy(drawn[1].request_id:find(result.process, 1, true))
    end)

    it("shows a file change's diff, which its own params do not carry", function()
      local drawn, on_approval_required = asking()
      send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)
      note(call, "item/started", {
        item = {
          id = "exec-1",
          type = "fileChange",
          changes = { { path = "/tmp/note.txt", kind = { type = "update" }, diff = "@@ -1 +1 @@\n-hello\n+goodbye\n" } },
        },
      })

      emit(call, { id = 7, method = "item/fileChange/requestApproval", params = { itemId = "exec-1" } })

      assert.equals("/tmp/note.txt", drawn[1].input.file_path)
      assert.is_true(vim.tbl_contains(drawn[1].input.details, "update /tmp/note.txt"))
      assert.is_true(vim.tbl_contains(drawn[1].input.details, "+goodbye"))
      -- Its params list no decisions at all, so the implied pair has to be offered.
      assert.same({ "accept", "decline" }, vim.tbl_map(function(option)
        return option.value
      end, drawn[1].options))
    end)

    it("stops owing a response once Codex resolves its own request", function()
      local drawn, on_approval_required = asking()
      send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)
      emit(call, { id = 88, method = "item/commandExecution/requestApproval", params = {} })
      local before = #call.stdin

      emit(call, { method = "serverRequest/resolved", params = { threadId = "thread-1", requestId = 88 } })

      assert.is_nil(Native.get(drawn[1].request_id))
      assert.equals(before, #call.stdin)
    end)

    it("refuses without asking when there is no chat to ask, rather than leaving the server blocked", function()
      send()
      local call = jobs.only_call()
      ready(call)

      emit(call, { id = 88, method = "item/commandExecution/requestApproval", params = {} })

      assert.equals(88, last(call).id)
      assert.equals("decline", last(call).result.decision)
      assert.equals(0, Native.count())
    end)

    it("still answers -32601 to a request it does not implement", function()
      -- `item/permissions/requestApproval` negotiates a grant rather than taking a decision, so it
      -- is deliberately not in the handled set.
      local _, on_approval_required = asking()
      send({ on_approval_required = on_approval_required })
      local call = jobs.only_call()
      ready(call)

      emit(call, { id = 9, method = "item/permissions/requestApproval", params = {} })

      assert.equals(9, last(call).id)
      assert.equals(-32601, last(call).error.code)
    end)
  end)
  it("does not route late notifications from a replaced process into its successor", function()
    local first = send()
    local old = jobs.only_call()
    ready(old)
    adapter:cancel(first.process)
    local second = send({ model = "gpt-6-astra" })
    note(old, "item/agentMessage/delta", { itemId = "late", delta = "stale" })
    finish(old)
    jobs.flush_exits()
    assert.equals(0, #second.responses)
    assert.equals(0, #second.chunks)
    assert.equals(second.process, Pool.get(CHAT).process_id)
  end)
end)
