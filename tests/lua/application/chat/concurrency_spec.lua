-- 同時に応答中にできるチャットの本数の上限（#645）。既定は無制限で、有効にしたときだけ
-- 機械が始める送信を待たせる。

local Config = require("vibing.config")
local view = require("vibing.presentation.chat.view")
local registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
local Concurrency = require("vibing.application.chat.concurrency")

describe("Concurrency", function()
  local originals = {}
  local responding = {}

  ---@param agent table?
  local function configure(agent)
    Config.get = function()
      return { agent = agent }
    end
  end

  before_each(function()
    originals.get = Config.get
    originals.list = view.list_chat_buffers
    originals.total_subagent_count = registry.total_subagent_count
    responding = {}
    registry.total_subagent_count = function()
      return 0
    end

    view.list_chat_buffers = function()
      local buffers = {}
      for bufnr, is_responding in pairs(responding) do
        buffers[bufnr] = {
          is_responding = function()
            return is_responding
          end,
        }
      end
      return buffers
    end
  end)

  after_each(function()
    Config.get = originals.get
    view.list_chat_buffers = originals.list
    registry.total_subagent_count = originals.total_subagent_count
  end)

  it("is unlimited by default, so nothing that works today starts waiting", function()
    configure({})
    responding = { [1] = true, [2] = true, [3] = true }

    assert.equals(0, Concurrency.limit())
    assert.is_false(Concurrency.at_capacity())
  end)

  it("counts only the chats that are actually responding", function()
    configure({ orchestration = { max_concurrent = 2 } })
    responding = { [1] = true, [2] = false, [3] = false }

    assert.equals(1, Concurrency.responding_count())
    assert.is_false(Concurrency.at_capacity())
  end)

  it("is at capacity once the configured number are responding", function()
    configure({ orchestration = { max_concurrent = 2 } })
    responding = { [1] = true, [2] = true }

    assert.is_true(Concurrency.at_capacity())
  end)

  it("survives a broken orchestration setting instead of failing every send", function()
    -- `vim.tbl_deep_extend("force", ...)` は非テーブルで既定値ごと置き換えるので、素朴に
    -- 索引すると boolean を index して落ちる。`chat_notifications` を読む側と同じ配慮
    configure({ orchestration = true })
    responding = { [1] = true }

    assert.equals(0, Concurrency.limit())
    assert.is_false(Concurrency.at_capacity())
  end)

  it("treats a negative limit as no limit rather than as capacity zero", function()
    configure({ orchestration = { max_concurrent = -1 } })

    assert.is_false(Concurrency.at_capacity())
  end)

  it("names both the current count and the escape hatch when it refuses", function()
    -- 「いま混んでいる」だけを返すと、モデルは同じ送信をそのまま再試行して同じ理由で断られ続ける
    configure({ orchestration = { max_concurrent = 1 } })
    responding = { [1] = true }

    local message = Concurrency.at_capacity_message()
    assert.is_truthy(message:find("queue_if_busy", 1, true))
    assert.is_truthy(message:find("max_concurrent = 1", 1, true))
  end)

  describe("subagents (#701)", function()
    it("folds in-flight subagents into the same total as responding chats", function()
      -- 5 chats within max_concurrent, but 2 of them together have 4 subagents running: the
      -- real fan-out is 6, not 2, and #692 hit a session limit at exactly this shape.
      configure({ orchestration = { max_concurrent = 5 } })
      responding = { [1] = true, [2] = true }
      registry.total_subagent_count = function()
        return 4
      end

      assert.equals(4, Concurrency.subagent_count())
      assert.is_true(Concurrency.at_capacity())
    end)

    it("does not count subagents when none are in flight", function()
      configure({ orchestration = { max_concurrent = 3 } })
      responding = { [1] = true, [2] = true }
      registry.total_subagent_count = function()
        return 0
      end

      assert.is_false(Concurrency.at_capacity())
    end)

    it("caps on subagent count alone via max_concurrent_subagents, independent of chats", function()
      configure({ orchestration = { max_concurrent_subagents = 2 } })
      responding = {}
      registry.total_subagent_count = function()
        return 2
      end

      assert.equals(0, Concurrency.limit())
      assert.equals(2, Concurrency.subagent_limit())
      assert.is_true(Concurrency.at_capacity())
    end)

    it("treats a negative subagent limit as no limit", function()
      configure({ orchestration = { max_concurrent_subagents = -1 } })
      registry.total_subagent_count = function()
        return 100
      end

      assert.equals(0, Concurrency.subagent_limit())
      assert.is_false(Concurrency.at_capacity())
    end)

    it("names the subagent count alongside the chat count when refusing", function()
      configure({ orchestration = { max_concurrent = 2 } })
      responding = { [1] = true }
      registry.total_subagent_count = function()
        return 3
      end

      local message = Concurrency.at_capacity_message()
      assert.is_truthy(message:find("3", 1, true))
      assert.is_truthy(message:find("max_concurrent = 2", 1, true))
    end)
  end)
end)
