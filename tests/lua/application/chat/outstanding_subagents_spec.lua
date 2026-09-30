-- #820: a turn that ends with background subagents outstanding must wake its own chat.
--
-- The assertion that matters is that `ProgrammaticSender.send` is reached — that is what "a new turn
-- is started on this chat" *is*, per the invariant in architecture.md ("the only way to deliver
-- anything to a chat is to start a new turn on it"). Asserting only that a notice was queued would
-- pass while the chat still sat there forever, since a queued item that is never flushed is exactly
-- the bug. So the real `message_queue` and `delivery_message` run, and only the two edges of the
-- system are stubbed: the chat buffer and the send.
local view = require("vibing.presentation.chat.view")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")
local AutoCompact = require("vibing.application.chat.auto_compact")
local Concurrency = require("vibing.application.chat.concurrency")
local CompletionNotifier = require("vibing.application.chat.completion_notifier")
local notify = require("vibing.core.utils.notify")

-- Held across reloads deliberately: the module has no state of its own and requires `message_queue`
-- inside `wake`, so a cached copy still reaches whichever queue instance is current.
local Outstanding = require("vibing.application.chat.outstanding_subagents")

describe("outstanding background subagents", function()
  local originals = {}
  local buffers = {}
  local sends = {}
  local warnings = {}
  local responding = {}
  local held = {}
  local at_capacity = false

  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    return bufnr
  end

  ---@return string body of the single notice that was sent
  local function sent_body()
    assert.equals(1, #sends)
    return sends[1].message
  end

  ---Fails naming the string that was missing, rather than "expected truthy, got nil".
  ---@param body string
  ---@param needle string
  local function mentions(body, needle)
    assert.is_truthy(body:find(needle, 1, true), string.format("notice does not mention %q:\n%s", needle, body))
  end

  ---@param body string
  ---@param needle string
  local function omits(body, needle)
    assert.is_nil(body:find(needle, 1, true), string.format("notice should not mention %q:\n%s", needle, body))
  end

  before_each(function()
    originals.get_chat_buffer = view.get_chat_buffer
    originals.send = ProgrammaticSender.send
    originals.before_delivery = AutoCompact.before_delivery
    originals.at_capacity = Concurrency.at_capacity
    originals.hold_for_capacity = CompletionNotifier.hold_for_capacity
    originals.warn = notify.warn

    buffers, sends, warnings, responding, held = {}, {}, {}, {}, {}
    at_capacity = false

    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        is_responding = function()
          return responding[bufnr] == true
        end,
        extract_user_message = function()
          return nil
        end,
      }
    end
    -- A delivered notice starts a turn, which is the whole point of the wake — so the stub has to
    -- leave the chat responding. Without that, `flush` reports "nothing started" and `wake` would
    -- correctly return false for a delivery that really did happen.
    ProgrammaticSender.send = function(bufnr, message, _, section)
      table.insert(sends, { bufnr = bufnr, message = message, section = section })
      responding[bufnr] = true
      return { success = true, bufnr = bufnr }
    end
    AutoCompact.before_delivery = function()
      return false
    end
    Concurrency.at_capacity = function()
      return at_capacity
    end
    CompletionNotifier.hold_for_capacity = function(bufnr)
      table.insert(held, bufnr)
    end
    notify.warn = function(message, title)
      table.insert(warnings, { message = message, title = title })
    end

    -- Fresh queue per example: `pending` is module state, and a notice left over from one example
    -- would be delivered alongside the next one's.
    package.loaded["vibing.application.chat.message_queue"] = nil
  end)

  after_each(function()
    view.get_chat_buffer = originals.get_chat_buffer
    ProgrammaticSender.send = originals.send
    AutoCompact.before_delivery = originals.before_delivery
    Concurrency.at_capacity = originals.at_capacity
    CompletionNotifier.hold_for_capacity = originals.hold_for_capacity
    notify.warn = originals.warn
    package.loaded["vibing.application.chat.message_queue"] = nil
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  -- The defect itself. A subagent that is still running has written no answer to its transcript, so
  -- recovery comes back empty — and empty recovery used to mean silence.
  it("wakes the chat when nothing could be recovered", function()
    local bufnr = make_chat()

    assert.is_true(Outstanding.wake({
      _unreported_subagents = {
        { task_id = "a1", description = "review reuse" },
        { task_id = "a2", description = "review efficiency" },
      },
      _recovered_subagents = {},
    }, bufnr))

    local body = sent_body()
    assert.equals(bufnr, sends[1].bufnr)
    mentions(body, "2 background subagent")
    mentions(body, "a1")
    mentions(body, "review efficiency")
  end)

  -- The other half of the same hole: with one recoverable out of three, keying the notice on the
  -- recovered list reported that one and silently abandoned the two still running.
  it("names the still-running ones alongside the recovered output", function()
    local bufnr = make_chat()

    assert.is_true(Outstanding.wake({
      _unreported_subagents = {
        { task_id = "a1", description = "review reuse" },
        { task_id = "a2", description = "review efficiency" },
        { task_id = "a3", description = "review altitude" },
      },
      _recovered_subagents = {
        { task_id = "a2", text = "found three hot loops" },
      },
    }, bufnr))

    local body = sent_body()
    mentions(body, "found three hot loops")
    -- The two with nothing on disk are the ones the model has to go and collect.
    mentions(body, "a1")
    mentions(body, "a3")
    mentions(body, "TaskOutput")
    -- ...and the recovered one must not be asked for again: its answer is in the notice already.
    mentions(body, "Nothing recoverable yet")
    omits(body:sub(body:find("Nothing recoverable yet", 1, true)), "a2")
  end)

  -- A third producer makes this path reachable on *every* turn, so a turn that backgrounded nothing
  -- must not wake anything. `_unreported_subagents` is absent on the overwhelming majority of turns.
  it("does not wake a turn that left nothing outstanding", function()
    local bufnr = make_chat()

    assert.is_false(Outstanding.wake({}, bufnr))
    assert.is_false(Outstanding.wake({ _unreported_subagents = {}, _recovered_subagents = {} }, bufnr))
    assert.equals(0, #sends)
    assert.equals(0, #warnings)
  end)

  -- `_cancelled` is both `:VibingCancel` and the kill that draws a question or an approval. Neither
  -- is an abandoned chat: the first was explicitly stopped by the human, and the second has a
  -- prompt on screen whose answer starts the next turn.
  it("does not wake a turn the human cancelled", function()
    local bufnr = make_chat()

    assert.is_false(Outstanding.wake({
      _cancelled = true,
      _unreported_subagents = { { task_id = "a1", description = "review reuse" } },
      _recovered_subagents = {},
    }, bufnr))
    assert.equals(0, #sends)
  end)

  -- A chat wiped while its long turn ran has nowhere to be woken, and must not be reported as a
  -- chat that "vanished without a BufDelete event".
  it("stays quiet when the chat is gone", function()
    local bufnr = make_chat()
    vim.api.nvim_buf_delete(bufnr, { force = true })

    local response = {
      _unreported_subagents = { { task_id = "a1", description = "review reuse" } },
      _recovered_subagents = {},
    }
    assert.is_false(Outstanding.wake(response, bufnr))
    assert.is_false(Outstanding.wake(response, nil))
    assert.equals(0, #sends)
    assert.equals(0, #warnings)
  end)

  -- Delivering is starting a turn, so it owes the concurrency limit. Nothing is dropped: the notice
  -- stays queued and `hold_for_capacity` is what gets it retried when a slot frees — this chat's own
  -- completion event has already been and gone.
  it("holds the notice for capacity instead of exceeding the limit", function()
    local bufnr = make_chat()
    at_capacity = true

    assert.is_false(Outstanding.wake({
      _unreported_subagents = { { task_id = "a1", description = "review reuse" } },
      _recovered_subagents = {},
    }, bufnr))
    assert.equals(0, #sends)
    assert.same({ bufnr }, held)
    -- Queued, not discarded: the retry has something to deliver.
    assert.is_true(require("vibing.application.chat.message_queue").has_pending(bufnr))
  end)

  -- "Woken" has to mean a turn started, not that the notice was queued. A chat mid-turn keeps the
  -- notice for its own completion event, and reporting that as woken is how a still-asleep chat gets
  -- counted as handled.
  it("does not claim to have woken a chat that was already responding", function()
    local bufnr = make_chat()
    responding[bufnr] = true

    assert.is_false(Outstanding.wake({
      _unreported_subagents = { { task_id = "a1", description = "review reuse" } },
      _recovered_subagents = {},
    }, bufnr))
    assert.equals(0, #sends)
    assert.is_true(require("vibing.application.chat.message_queue").has_pending(bufnr))
  end)

  describe("the notice body", function()
    -- A task launched without a brief is named by its id alone; formatting `nil` into the line
    -- would put the string "nil" in front of the model.
    it("names a task that carried no description", function()
      local body = Outstanding.notice_body({ { task_id = "a1" } }, {})
      mentions(body, "`a1`")
      omits(body, "nil")
    end)

    -- Everything outstanding was recovered, so there is nothing left to collect and the notice must
    -- not tell the model to go and fetch it.
    it("asks for nothing more when every task was recovered", function()
      local body = Outstanding.notice_body(
        { { task_id = "a1", description = "review reuse" } },
        { { task_id = "a1", text = "no duplication found" } }
      )
      mentions(body, "no duplication found")
      omits(body, "Nothing recoverable yet")
      omits(body, "TaskOutput")
    end)
  end)
end)
