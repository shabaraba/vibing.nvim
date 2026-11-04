---@diagnostic disable: undefined-field
--- Command Code's own `session/request_permission`, which is a second gate and not vibing's hook.
---
--- Measured against Command Code 1.88.2 (2026-11-04): `commandcode --mod <bridge> --yolo acp` still
--- sends this request for a shell command, and a client that answers with a JSON-RPC error (what
--- vibing.nvim did before this module existed) has the call marked `failed` with "Permission denied
--- by the user." and the turn ends. So these assertions guard that the request is answered, that the
--- single-use option is the one taken, and that the session-wide one never is.
local MODULE = "vibing.infrastructure.adapter.modules.commandcode_native_approval"
local PROCESS = "vibing.infrastructure.adapter.modules.duplex_process"

describe("commandcode_native_approval", function()
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

  local function record(bridge)
    return { job_id = 11, process_id = "p1", _rpc = { hook_installed = bridge ~= false } }
  end

  --- The four options Command Code 1.88.2 offers, verbatim and in its own order -- the session-wide
  --- one is not first, which is why "the first option offered" would be the wrong rule.
  local ALLOW_ONCE = { optionId = "allow_once", name = "Allow once", kind = "allow_once" }
  local REJECT_ONCE = { optionId = "reject_once", name = "Reject", kind = "reject_once" }
  local ALLOW_ALWAYS = { optionId = "allow_always", name = "Always allow", kind = "allow_always" }
  local REJECT_ALWAYS = { optionId = "reject_always", name = "Always reject", kind = "reject_always" }

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
          kind = "execute",
          title = "Shell: echo hi",
          rawInput = { command = "echo hi" },
        },
        options = options,
      },
    }
  end

  it("handles Command Code's permission request and nothing else", function()
    assert.is_true(Approval.handles("session/request_permission"))
    assert.is_false(Approval.handles("session/update"))
    assert.is_false(Approval.handles("session/request_permissions"))
    assert.is_false(Approval.handles(nil))
  end)

  -- The session-wide option would retire the engine gate for every later call in the chat, widening
  -- what a *future* turn may do without the request being seen at all. Scoping to the single call
  -- keeps the mod bridge the only thing that accumulates permission.
  it("selects the single-use option, never the session-wide one", function()
    local answered, notice = Approval.handle(record(), request({ ALLOW_ONCE, REJECT_ONCE, ALLOW_ALWAYS, REJECT_ALWAYS }))

    assert.is_true(answered)
    assert.same({
      { jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "selected", optionId = "allow_once" } } },
    }, vim.tbl_map(function(call)
      return call.payload
    end, written))
    -- Silent on the ordinary path: it reports a decision vibing's own gate already made and
    -- already rendered.
    assert.is_nil(notice)
  end)

  -- Without the mod bridge, Command Code's own gate is the only one left. Approving the call would
  -- run it with no vibing.nvim check behind it, so the single-use option is not taken.
  it("refuses rather than approving when the mod bridge is not installed", function()
    local answered, notice = Approval.handle(record(false), request({ ALLOW_ONCE, REJECT_ONCE }))

    assert.is_true(answered)
    assert.same(
      { jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "selected", optionId = "reject_once" } } },
      written[1].payload
    )
    assert.is_truthy(notice)
    assert.is_truthy(notice:find("no vibing.nvim permission bridge", 1, true))
  end)

  it("answers on the process that asked", function()
    local asking = record()
    Approval.handle(asking, request({ ALLOW_ONCE }))
    assert.equals(asking, written[1].record)
  end)

  -- A withheld reply is not a refusal here: Command Code blocks inside its own turn waiting for one,
  -- so a silent drop hangs the chat with no way out but a cancel.
  it("refuses out loud when no single-use approval is on offer", function()
    local answered, notice = Approval.handle(record(), request({ ALLOW_ALWAYS, REJECT_ONCE }))

    assert.is_true(answered)
    assert.same(
      { jsonrpc = "2.0", id = 0, result = { outcome = { outcome = "selected", optionId = "reject_once" } } },
      written[1].payload
    )
    assert.is_truthy(notice)
    assert.is_truthy(notice:find("Shell: echo hi", 1, true))
  end)

  -- The ACP `cancelled` outcome, which Command Code reports back as a cancelled turn rather than a
  -- hang.
  it("cancels the request when Command Code offered no option at all", function()
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

    -- A notice about a refusal that never reached Command Code would describe a turn that is still
    -- running.
    it("reports a refusal as unanswered, and says nothing about it", function()
      load(false)
      local answered, notice = Approval.handle(record(), request({ REJECT_ONCE }))

      assert.is_false(answered)
      assert.is_nil(notice)
    end)
  end)
end)
