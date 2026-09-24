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
  --- @param ids table
  --- @param stopped boolean? what the adapter answers; the real one says whether anything was
  ---   actually asked to stop, which is false whenever the process has already been reclaimed
  --- @return table chat_buffer, table cancelled
  local function make_buffer(ids, stopped)
    local cancelled = {}
    local chat_buffer = setmetatable({
      _current_turn_id = ids.turn_id,
      _current_process_id = ids.process_id,
      -- `stop_turn`, not `cancel`: a user pressing cancel wants this request stopped, not the
      -- chat's resident CLI process thrown away (#777). The base adapter's `stop_turn` delegates
      -- to `cancel`, so on the oneshot transport the two are still the same kill.
      _current_adapter = {
        stop_turn = function(_, id)
          table.insert(cancelled, id)
          return stopped ~= false
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

  it("reports false when the adapter had nothing left to stop", function()
    -- A resident process is reclaimed independently of its turns, so the id a chat holds routinely
    -- names a process that is gone. Reporting that as a successful cancel is what left the chat
    -- `responding` with nothing running.
    local chat_buffer, cancelled = make_buffer({ turn_id = "turn-1", process_id = "process-1" }, false)

    assert.is_false(chat_buffer:cancel_request())
    assert.same({ "process-1" }, cancelled)
  end)
end)

-- `:VibingCancel` / `:VibingCancelTree` go through `cancel_turn`, which adds exactly one thing to
-- `cancel_request`: when nothing could be stopped, the chat's own turn is folded here. Without it
-- `_is_sending` is cleared only by `_handle_response`, which for a process that no longer exists
-- never runs -- the chat reports `responding` for good and cancel looks like a no-op.
describe("ChatBuffer:cancel_turn", function()
  local ChatBuffer = require("vibing.presentation.chat.buffer")

  --- @return table chat_buffer, table state
  local function make_buffer(stopped)
    local state = { finished = 0 }
    local chat_buffer = setmetatable({
      _current_turn_id = "turn-1",
      _current_process_id = "process-1",
      _is_sending = true,
      _current_adapter = {
        stop_turn = function()
          return stopped
        end,
      },
    }, { __index = ChatBuffer })
    chat_buffer._finish_turn = function()
      state.finished = state.finished + 1
    end
    return chat_buffer, state
  end

  it("folds the chat's own turn when there was nothing left to stop", function()
    local chat_buffer, state = make_buffer(false)

    assert.is_true(chat_buffer:cancel_turn())
    assert.is_false(chat_buffer:is_sending())
    assert.is_nil(chat_buffer._current_process_id)
    assert.is_nil(chat_buffer._current_turn_id)
    -- Folded through the one merge point every turn ends at, so the unsent section, the save and
    -- `VibingResponseDone` are not written a second time here.
    assert.equals(1, state.finished)
  end)

  it("leaves the turn to the CLI when the adapter did stop it", function()
    -- An interrupt is answered with a `result`, asynchronously; folding here as well would end the
    -- turn twice and draw two unsent sections.
    local chat_buffer, state = make_buffer(true)

    assert.is_true(chat_buffer:cancel_turn())
    assert.is_true(chat_buffer:is_sending())
    assert.equals(0, state.finished)
  end)

  it("folds nothing in a chat that is not running a turn", function()
    local chat_buffer, state = make_buffer(false)
    chat_buffer._is_sending = false
    chat_buffer._current_turn_id = nil

    assert.is_false(chat_buffer:cancel_turn())
    assert.equals(0, state.finished)
  end)
end)
