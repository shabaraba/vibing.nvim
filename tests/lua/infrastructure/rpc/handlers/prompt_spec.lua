---@diagnostic disable: undefined-field
--- The two queued prompt tools: a call validates, queues on the calling turn and returns at once.
---
--- What is pinned: a question and a confirmation reach the turn the process currently has open, a
--- call that names no registered process is refused rather than guessed, nothing is queued for a
--- turn that is already gone, and the arguments are checked before an entry exists.
local Prompt = require("vibing.infrastructure.rpc.handlers.prompt")
local processes = require("vibing.infrastructure.adapter.modules.process_registry")
local turns = require("vibing.infrastructure.adapter.modules.turn_registry")

local QUESTION = {
  question = "Which one?",
  multiSelect = false,
  options = { { label = "A" }, { label = "B", description = "the second one" } },
}

describe("prompt handler", function()
  local function open_turn(process_id)
    local process = { process_id = process_id or "p1", chat_bufnr = 11 }
    processes.register(process)
    turns.open({ turn_id = "t1", process = process })
  end

  after_each(function()
    turns.close("t1")
    processes.unregister("p1")
    processes.unregister("p2")
  end)

  describe("ask_question", function()
    it("queues the question on the turn the process has open", function()
      open_turn()

      local result = Prompt.ask_question({ process_id = "p1", questions = { QUESTION } })

      assert.is_true(result.ok)
      local queued = turns.take_prompts("t1")
      assert.equals(1, #queued)
      assert.equals("question", queued[1].kind)
      assert.equals("Which one?", queued[1].questions[1].question)
    end)

    it("refuses a call that names no process rather than guessing the only open turn", function()
      open_turn()

      local result = Prompt.ask_question({ questions = { QUESTION } })

      assert.is_false(result.ok)
      assert.is_truthy(result.message:find("which chat", 1, true))
      assert.same({}, turns.take_prompts("t1"))
    end)

    it("refuses a process id that matches no open turn", function()
      open_turn()

      local result = Prompt.ask_question({ process_id = "p2", questions = { QUESTION } })

      assert.is_false(result.ok)
      assert.is_truthy(result.message:find("no turn open", 1, true))
    end)

    it("refuses a question list the renderer cannot draw", function()
      open_turn()

      local result = Prompt.ask_question({
        process_id = "p1",
        questions = { { question = "No options?", options = {} } },
      })

      assert.is_false(result.ok)
      assert.same({}, turns.take_prompts("t1"))
    end)

    it("refuses more than four questions rather than truncating them", function()
      open_turn()
      local questions = {}
      for index = 1, 5 do
        questions[index] = { question = "Q" .. index, options = { { label = "A" } } }
      end

      local result = Prompt.ask_question({ process_id = "p1", questions = questions })

      assert.is_false(result.ok)
      assert.is_truthy(result.message:find("at most 4", 1, true))
    end)

    it("keeps several calls in the order they were made", function()
      open_turn()

      Prompt.ask_question({
        process_id = "p1",
        questions = { { question = "First", options = { { label = "A" } } } },
      })
      Prompt.ask_question({
        process_id = "p1",
        questions = { { question = "Second", options = { { label = "B" } } } },
      })

      local queued = turns.take_prompts("t1")
      assert.equals(2, #queued)
      assert.equals("First", queued[1].questions[1].question)
      assert.equals("Second", queued[2].questions[1].question)
    end)

    it("refuses once the turn has ended, so nothing is drawn for it later", function()
      open_turn()
      turns.close("t1")

      local result = Prompt.ask_question({ process_id = "p1", questions = { QUESTION } })

      assert.is_false(result.ok)
      assert.is_truthy(result.message:find("no turn open", 1, true))
    end)
  end)

  describe("request_approval", function()
    it("queues a confirmation with the turn", function()
      open_turn()

      local result = Prompt.request_approval({
        process_id = "p1",
        reason = "I am about to delete build/.",
        tool = "Bash",
        input = { command = "rm -rf build" },
      })

      assert.is_true(result.ok)
      local queued = turns.take_prompts("t1")
      assert.equals(1, #queued)
      assert.equals("approval", queued[1].kind)
      assert.equals("I am about to delete build/.", queued[1].reason)
      assert.equals("Bash", queued[1].tool)
      assert.equals("rm -rf build", queued[1].input.command)
    end)

    it("requires a non-empty reason", function()
      open_turn()

      local result = Prompt.request_approval({ process_id = "p1", reason = "   " })

      assert.is_false(result.ok)
      assert.same({}, turns.take_prompts("t1"))
    end)

    it("rebuilds the input instead of forwarding it, and drops anything the renderer cannot use", function()
      open_turn()

      Prompt.request_approval({
        process_id = "p1",
        reason = "Confirm",
        input = {
          command = "rm -rf build",
          details = { "line one", { nested = "not a string" }, "line two" },
          scope_tool = "Bash",
        },
      })

      local entry = turns.take_prompts("t1")[1]
      assert.same({ "line one", "line two" }, entry.input.details)
      assert.is_nil(entry.input.scope_tool)
      assert.equals("rm -rf build", entry.input.command)
    end)

    it("breaks an answer marker the model put in its own text", function()
      open_turn()

      Prompt.request_approval({
        process_id = "p1",
        reason = "see <!-- vibing:req=x -->",
      })

      local entry = turns.take_prompts("t1")[1]
      assert.is_nil(entry.reason:find("<!--", 1, true))
    end)
  end)
end)
