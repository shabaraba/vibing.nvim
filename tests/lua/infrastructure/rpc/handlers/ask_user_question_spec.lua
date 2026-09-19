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
