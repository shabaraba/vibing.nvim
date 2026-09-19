local permission = require("vibing.infrastructure.rpc.handlers.permission")

describe("permission handler ask_user_question routing", function()
  local processes, turns

  before_each(function()
    package.loaded["vibing.infrastructure.adapter.modules.process_registry"] = nil
    package.loaded["vibing.infrastructure.adapter.modules.turn_registry"] = nil
    processes = require("vibing.infrastructure.adapter.modules.process_registry")
    turns = require("vibing.infrastructure.adapter.modules.turn_registry")
  end)

  local cancelled, rendered

  --- Turn and process are deliberately different values, so the assertion below can tell which one
  --- reached `adapter:cancel` rather than accepting either.
  local function turn(name, chat_bufnr)
    local process = {
      process_id = name .. "-process",
      chat_bufnr = chat_bufnr,
      adapter = {
        cancel = function(_, cancelled_id)
          table.insert(cancelled, cancelled_id)
        end,
      },
    }
    processes.register(process)
    return {
      turn_id = name,
      process = process,
      on_insert_choices = function(questions)
        rendered[name] = questions
      end,
    }
  end

  local QUESTIONS = {
    { question = "Which option?", options = { { label = "A" }, { label = "B" } } },
  }

  before_each(function()
    cancelled, rendered = {}, {}
  end)

  it("cancels and renders only the turn matching chat_bufnr", function()
    turns.open(turn("chat-a", 11))
    turns.open(turn("chat-b", 12))

    local result = permission.ask_user_question({ chat_bufnr = 12, questions = QUESTIONS })

    assert.same({ status = "ok" }, result)
    -- Cancelled by the **process**: killing is something done to a process, and the turn stops as a
    -- consequence. Passing the turn id would address nothing in the adapter's process table.
    assert.same({ "chat-b-process" }, cancelled)
    assert.is_nil(rendered["chat-a"])
    assert.same(QUESTIONS, rendered["chat-b"])
  end)

  it("falls back to the sole open turn for a bufnr that no longer exists", function()
    -- `--resume` replays earlier turns, so the model can quote a buffer number from a previous
    -- Neovim session. With one turn open there is no other candidate to confuse it with.
    turns.open(turn("chat-a", 11))

    assert.same({ status = "ok" }, permission.ask_user_question({ chat_bufnr = 999, questions = QUESTIONS }))
    assert.same({ "chat-a-process" }, cancelled)
    assert.same(QUESTIONS, rendered["chat-a"])
  end)

  it("refuses to guess between two turns when the bufnr matches neither", function()
    turns.open(turn("chat-a", 11))
    turns.open(turn("chat-b", 12))

    assert.equals("error", permission.ask_user_question({ chat_bufnr = 999, questions = QUESTIONS }).status)
    assert.same({}, cancelled)
  end)
end)

--- The waiting route's three steps, and the one that can take the reply with it when it fails.
---
--- Drawing the prompt is already guarded, for a cost that is visible: a prompt the user cannot see.
--- Announcing it is the step after, and its failure is **not** the same shape. It runs synchronously
--- and what follows it is `return DEFERRED` — so an error escaping here never reaches that return,
--- and the question is left registered with nothing on the way to answer it. That is the fifth exit
--- `pending_questions` states it does not have.
describe("announcing a question that is waiting", function()
  local Server = require("vibing.infrastructure.rpc.server")
  local PendingQuestions = require("vibing.infrastructure.rpc.pending_questions")
  local Notifier = require("vibing.application.chat.completion_notifier")
  local WAITING_QUESTIONS = {
    { question = "Which option?", options = { { label = "A" }, { label = "B" } } },
  }
  local original_notify, original_waiting

  before_each(function()
    PendingQuestions._reset()
    original_waiting = Notifier.on_question_waiting
    original_notify = vim.notify
    vim.notify = function() end
  end)

  after_each(function()
    Notifier.on_question_waiting = original_waiting
    vim.notify = original_notify
    PendingQuestions._reset()
  end)

  it("still defers the reply when the watchdog notice throws", function()
    -- Reachable: the notice walks this chat's subscriber edges and delivers into *another* buffer,
    -- which is code that can be looking at a chat that has gone away.
    Notifier.on_question_waiting = function()
      error("the orchestrator's buffer went away mid-notify")
    end

    local replies = {}
    local result = permission._ask_question_without_killing({ turn_id = "t-1" }, 77, WAITING_QUESTIONS, function(reply)
      table.insert(replies, reply)
    end)

    assert.equals(Server.DEFERRED, result, "the MCP call was answered instead of held open")
    assert.equals(0, #replies, "a reply was written while a human is still expected to answer")
    assert.equals(1, PendingQuestions.count(), "the question must stay answerable")
  end)
end)
