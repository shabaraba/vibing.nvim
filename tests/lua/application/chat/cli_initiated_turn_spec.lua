-- A turn the resident CLI started by itself has to reach the chat as a turn of its own. The edges are
-- stubbed — the chat buffer and the send — and the event that ends a wait is the real one.
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local Events = require("vibing.core.events")
local notify = require("vibing.core.utils.notify")
local CliTurn = require("vibing.application.chat.cli_initiated_turn")

describe("a turn the CLI started by itself", function()
  local originals = {}
  local bufnr
  local state
  local adopted
  local warnings

  local handles

  local function handle()
    local h = { discarded = 0, held = true }
    table.insert(handles, h)
    h.pending = function()
      return h.held
    end
    -- Like the adapter's: a turn already taken or handed back is not handed back again.
    h.discard = function()
      if h.held then
        h.discarded = h.discarded + 1
        h.held = false
      end
    end
    return h
  end

  local function settle()
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    vim.wait(1000, function()
      return drained
    end)
  end

  before_each(function()
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.warn = notify.warn
    originals.wait_ms = CliTurn.WAIT_MS
    CliTurn._reset()

    bufnr = vim.api.nvim_create_buf(false, true)
    state = { responding = false, finishing = false, draft = nil, stops_short = false }
    adopted, warnings, handles = {}, {}, {}

    view.get_chat_buffer = function(b)
      if b ~= bufnr then
        return nil
      end
      return {
        is_responding = function()
          return state.responding
        end,
        is_finishing_turn = function()
          return state.finishing
        end,
        extract_user_message = function()
          return state.draft
        end,
      }
    end
    -- Stands in for the whole send path down to the adapter, which takes the held lines when it opens
    -- the turn. `stops_short` is a send that reports success and never got that far.
    ProgrammaticSender.send = function(b, message, _, delivery, opts)
      table.insert(adopted, { bufnr = b, message = message, kind = delivery.kind, adopt = opts.adopt_cli_turn })
      if not state.stops_short then
        for _, h in ipairs(handles) do
          h.held = false
        end
      end
      return { success = true, bufnr = b }
    end
    notify.warn = function(message)
      table.insert(warnings, message)
    end
  end)

  after_each(function()
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    notify.warn = originals.warn
    CliTurn.WAIT_MS = originals.wait_ms
    CliTurn._reset()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("opens it at once on an idle chat, announced by the completion drawn between turns", function()
    local h = handle()
    CliTurn.adopt(bufnr, "\n⏺ Subagent finished: probe (1s)\n", h)

    assert.same(
      { { bufnr = bufnr, message = "⏺ Subagent finished: probe (1s)", kind = "Notice", adopt = true } },
      adopted
    )
    assert.equals(0, h.discarded)
    assert.equals(0, #warnings)
  end)

  it("says what happened when nothing was drawn between turns", function()
    CliTurn.adopt(bufnr, "", handle())

    assert.equals(CliTurn.DEFAULT_NOTICE, adopted[1].message)
  end)

  -- The CLI starts its own turn milliseconds after the previous `result`, while `_finish_turn` is
  -- still queued. Refusing there would drop the ordinary case.
  it("waits for a chat still finishing its previous turn, and opens it on that turn's completion", function()
    state.finishing = true
    local h = handle()
    CliTurn.adopt(bufnr, "done", h)
    assert.equals(0, #adopted, "opened a turn over one that had not finished writing")

    state.finishing = false
    Events.emit_response_done(bufnr)
    settle()

    assert.equals(1, #adopted)
    assert.equals(0, h.discarded)
  end)

  it("does nothing when the turn was taken elsewhere while it waited", function()
    state.responding = true
    local h = handle()
    CliTurn.adopt(bufnr, "done", h)
    h.held = false

    state.responding = false
    Events.emit_response_done(bufnr)
    settle()

    assert.equals(0, #adopted)
  end)

  it("declines, out loud, when the chat has an unsent message", function()
    state.draft = "half-written"
    local h = handle()
    CliTurn.adopt(bufnr, "done", h)

    assert.equals(0, #adopted)
    assert.equals(1, h.discarded)
    assert.equals(1, #warnings)
  end)

  it("declines a chat that is gone", function()
    local h = handle()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    CliTurn.adopt(bufnr, "done", h)

    assert.equals(0, #adopted)
    assert.equals(1, h.discarded)
  end)

  -- A session conflict or a non-resident transport ends the send before the adapter, and the send
  -- still reports success. Only the handle says whether the lines were taken.
  it("hands the lines back when the send stopped short of the adapter, whatever it returned", function()
    state.stops_short = true
    local h = handle()
    CliTurn.adopt(bufnr, "done", h)

    assert.equals(1, h.discarded)
    assert.equals(1, #warnings)
  end)

  it("gives up waiting for a chat whose previous turn never finishes writing", function()
    CliTurn.WAIT_MS = 20
    state.finishing = true
    local h = handle()
    CliTurn.adopt(bufnr, "done", h)

    assert.is_true(vim.wait(1000, function()
      return h.discarded == 1
    end))
    assert.equals(0, #adopted)
  end)
end)
