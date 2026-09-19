-- `ChatBuffer:cancel_request()` stops a CLI **process**, and the chat buffer therefore has to
-- remember the process id separately from the turn id even though the two are minted together
-- (#774).
--
-- The separation is not cosmetic: `send_message()` calls `cancel_request()` *before* every send as
-- a zombie reap, which is after the previous turn ended and unregistered itself. At that moment
-- nothing can resolve a turn id back to the process that ran it, so a buffer holding only the turn
-- would silently reap nothing -- and the guard returns `false` rather than erroring, which is why
-- no existing test noticed.
describe("ChatBuffer:cancel_request", function()
  local ChatBuffer = require("vibing.presentation.chat.buffer")

  --- A ChatBuffer with just enough state for the method under test, and a stub adapter that
  --- records what it was asked to cancel. `_get_active_adapter` returns `_current_adapter` when
  --- set, so no real adapter or window is needed.
  --- @return table chat_buffer, table cancelled
  local function make_buffer(ids)
    local cancelled = {}
    local chat_buffer = setmetatable({
      _current_turn_id = ids.turn_id,
      _current_process_id = ids.process_id,
      _current_adapter = {
        cancel = function(_, id)
          table.insert(cancelled, id)
        end,
      },
    }, { __index = ChatBuffer })
    return chat_buffer, cancelled
  end

  it("cancels by the process id, never by the turn id", function()
    local chat_buffer, cancelled = make_buffer({ turn_id = "turn-1", process_id = "process-1" })

    assert.is_true(chat_buffer:cancel_request())
    assert.same({ "process-1" }, cancelled)
  end)

  it("reaps a process whose turn has already ended", function()
    -- The case the field exists for: the turn is forgotten, the process is not, and the zombie is
    -- still killable. Holding only the turn id here would make this a silent no-op.
    local chat_buffer, cancelled = make_buffer({ turn_id = nil, process_id = "process-1" })

    assert.is_true(chat_buffer:cancel_request())
    assert.same({ "process-1" }, cancelled)
  end)

  it("does nothing, and cancels nothing, when no process was ever recorded", function()
    -- `cancel(nil)` means "every process this adapter owns", and one adapter instance is shared
    -- across chats -- so reaching the adapter at all here would kill other chats' turns.
    local chat_buffer, cancelled = make_buffer({ turn_id = "turn-1", process_id = nil })

    assert.is_false(chat_buffer:cancel_request())
    assert.same({}, cancelled)
  end)
end)
