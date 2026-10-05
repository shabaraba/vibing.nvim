local helper = require("tests.helpers.adapter_stream")
local Adapter = require("vibing.infrastructure.adapter.codex_cli")
local Pool = require("vibing.infrastructure.adapter.modules.duplex_pool")
local Registry = require("vibing.infrastructure.adapter.modules.turn_registry")
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
  it("surfaces initialization errors once and reclaims the bad process", function()
    local result = send()
    local call = jobs.only_call()
    emit(call, { id = last(call).id, error = { message = "unsupported initialize" } })
    assert.matches("unsupported initialize", result.responses[1].error)
    assert.is_nil(Pool.get(CHAT))
    jobs.flush_exits()
    assert.equals(1, #result.responses)
  end)
  it("answers native approval requests with a denial rather than leaving the server blocked", function()
    send()
    local call = jobs.only_call()
    ready(call)
    emit(call, { id = 88, method = "item/commandExecution/requestApproval", params = {} })
    assert.equals(88, last(call).id)
    assert.equals("decline", last(call).result.decision)
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
