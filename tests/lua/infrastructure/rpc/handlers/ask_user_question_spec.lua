local permission = require("vibing.infrastructure.rpc.handlers.permission")

describe("permission handler ask_user_question routing", function()
  local registry

  before_each(function()
    package.loaded["vibing.infrastructure.adapter.modules.active_stream_registry"] = nil
    registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
  end)

  after_each(function()
    registry.unregister("chat-a")
    registry.unregister("chat-b")
  end)

  it("cancels and renders only the stream matching chat_bufnr", function()
    local cancelled = {}
    local rendered = {}
    local function stream(handle_id, chat_bufnr)
      return {
        handle_id = handle_id,
        chat_bufnr = chat_bufnr,
        adapter = {
          cancel = function(_, cancelled_handle)
            table.insert(cancelled, cancelled_handle)
          end,
        },
        on_insert_choices = function(questions)
          rendered[handle_id] = questions
        end,
      }
    end

    registry.register(stream("chat-a", 11))
    registry.register(stream("chat-b", 12))

    local questions = {
      { question = "Which option?", options = { { label = "A" }, { label = "B" } } },
    }
    local result = permission.ask_user_question({ chat_bufnr = 12, questions = questions })

    assert.same({ status = "ok" }, result)
    assert.same({ "chat-b" }, cancelled)
    assert.is_nil(rendered["chat-a"])
    assert.same(questions, rendered["chat-b"])
  end)
end)
