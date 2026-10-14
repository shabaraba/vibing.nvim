---@diagnostic disable: undefined-field
--- Grok's own `session/request_permission`, which is a second gate and not vibing's hook.
---
--- Measured against grok 1.0.50: with a denying `pre_tool_use` hook, six tool calls in one turn were
--- refused and **no** `session/request_permission` was sent at all. So a request that reaches this
--- module is for a call vibing's gate has already permitted, and these assertions guard what is left
--- to decide: that the single-use option is the one taken, that the session-wide one never is, and
--- that every request is answered rather than dropped -- grok blocks inside its own turn waiting.
local MODULE = "vibing.infrastructure.adapter.modules.grok_native_approval"
local PROCESS = "vibing.infrastructure.adapter.modules.duplex_process"

describe("grok_native_approval", function()
  local Approval, written

  --- @param sent boolean what the stubbed `duplex_process.write` reports
  local function load(sent)
    written = {}
    package.loaded[PROCESS] = {
      write = function(record, payload)
        table.insert(written, { record = record, payload = payload })
        return sent
      end,
    }
    package.loaded[MODULE] = nil
    Approval = require(MODULE)
  end

  before_each(function()
    load(true)
  end)

  after_each(function()
    package.loaded[MODULE] = nil
    package.loaded[PROCESS] = nil
  end)

  local function record()
    return { job_id = 11, process_id = "p1" }
  end

  --- The three options grok 1.0.50 offers for an edit, verbatim and in its own order -- the
  --- session-wide one first, which is why "the first option offered" would be the wrong rule.
  local ALLOW_ALWAYS =
    { optionId = "allow-edits-session", name = "Yes, allow all edits during this session", kind = "allow_always" }
  local ALLOW_ONCE = { optionId = "allow-once", name = "Yes", kind = "allow_once" }
  local REJECT_ONCE =
    { optionId = "reject-once", name = "No, and tell Grok what to do differently", kind = "reject_once" }

  --- @param options table[]|nil
  local function request(options)
    return {
      jsonrpc = "2.0",
      id = 0,
      method = "session/request_permission",
      params = {
        sessionId = "01a1",
        toolCall = {
          toolCallId = "call-738d-0",
          kind = "edit",
          title = "Write `/tmp/x/deny.txt`",
          rawInput = { file_path = "/tmp/x/deny.txt", content = "hi\n" },
        },
        options = options,
      },
    }
  end

  it("handles grok's permission request and nothing else", function()
    assert.is_true(Approval.handles("session/request_permission"))
    assert.is_false(Approval.handles("session/update"))
    assert.is_false(Approval.handles("session/request_permissions"))
    assert.is_false(Approval.handles(nil))
  end)

  -- The session-wide option would retire grok's gate for every later call in the chat, widening
  -- what a *future* turn may do without grok consulting vibing's hook at all. Scoping to the single
  -- call keeps vibing's gate the only thing that accumulates permission.
  it("selects the single-use option, never the session-wide one", function()
    local answered, notice = Approval.handle(record(), request({ ALLOW_ALWAYS, ALLOW_ONCE, REJECT_ONCE }))

    assert.is_true(answered)
    assert.same({
      { jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "selected", optionId = "allow-once" } } },
    }, vim.tbl_map(function(call)
      return call.payload
    end, written))
    -- Silent on the ordinary path: it reports a decision vibing's own gate already made and
    -- already rendered.
    assert.is_nil(notice)
  end)

  it("answers on the process that asked", function()
    local asking = record()
    Approval.handle(asking, request({ ALLOW_ONCE }))
    assert.equals(asking, written[1].record)
  end)

  -- A withheld reply is not a refusal here: grok blocks inside its own turn waiting for one, so a
  -- silent drop hangs the chat with no way out but a cancel.
  it("refuses out loud when no single-use approval is on offer", function()
    local answered, notice = Approval.handle(record(), request({ ALLOW_ALWAYS, REJECT_ONCE }))

    assert.is_true(answered)
    assert.same(
      { jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "selected", optionId = "reject-once" } } },
      written[1].payload
    )
    assert.is_truthy(notice)
    assert.is_truthy(notice:find("Write `/tmp/x/deny.txt`", 1, true))
  end)

  -- The ACP `cancelled` outcome, which grok reports back as a cancelled turn rather than a hang.
  it("cancels the request when grok offered no option at all", function()
    local answered, notice = Approval.handle(record(), request({}))

    assert.is_true(answered)
    assert.same({ jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "cancelled" } } }, written[1].payload)
    assert.is_truthy(notice)
  end)

  it("cancels a request that carries no options field", function()
    local answered = Approval.handle(record(), request(nil))

    assert.is_true(answered)
    assert.same({ jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "cancelled" } } }, written[1].payload)
  end)

  describe("when the write fails", function()
    it("reports the single-use answer as unanswered", function()
      load(false)
      local answered, notice = Approval.handle(record(), request({ ALLOW_ONCE }))

      assert.is_false(answered)
      assert.is_nil(notice)
    end)

    -- A notice about a refusal that never reached grok would describe a turn that is still running.
    it("reports a refusal as unanswered, and says nothing about it", function()
      load(false)
      local answered, notice = Approval.handle(record(), request({ REJECT_ONCE }))

      assert.is_false(answered)
      assert.is_nil(notice)
    end)
  end)
end)
