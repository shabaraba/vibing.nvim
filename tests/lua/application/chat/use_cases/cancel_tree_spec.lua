-- サブツリー全体の走行中ターンをまとめて止める（#645）。窓なしで作られたワーカーは画面に
-- 出ないので、`:VibingCancel` を人数分繰り返すには、まずどこにいるかを知る必要がある。

local Git = require("vibing.core.utils.git")
local ChatFiles = require("tests.helpers.chat_files")
local view = require("vibing.presentation.chat.view")

describe("CancelTree", function()
  local CancelTree, MessageQueue
  local originals = {}
  local dir
  local buffers = {}
  local running = {}
  local cancelled = {}
  local pending_at_cancel = {}

  ---@param name string
  ---@return number bufnr
  local function open_buffer(name)
    local bufnr = vim.fn.bufadd(dir .. "/" .. name)
    vim.fn.bufload(bufnr)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    originals.get_root = Git.get_root
    originals.get_chat_buffer = view.get_chat_buffer

    dir = vim.fn.resolve(vim.fn.tempname())
    vim.fn.mkdir(dir, "p")
    buffers, running, cancelled, pending_at_cancel = {}, {}, {}, {}

    Git.get_root = function()
      return dir
    end

    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        cancel_request = function()
          -- 順序の観測点。配達待ちを残したまま止めると、`wrapped_on_done` が同期で走って
          -- キューが配られ、止めたそばから同じチャットが再稼働する
          pending_at_cancel[bufnr] = MessageQueue.has_pending(bufnr)
          if not running[bufnr] then
            return false
          end
          table.insert(cancelled, bufnr)
          return true
        end,
      }
    end

    for _, name in ipairs({
      "vibing.application.chat.chat_locator",
      "vibing.application.chat.orchestration_tree",
      "vibing.application.chat.message_queue",
      "vibing.application.chat.completion_notifier",
      "vibing.application.chat.use_cases.cancel_tree",
    }) do
      package.loaded[name] = nil
    end
    MessageQueue = require("vibing.application.chat.message_queue")
    CancelTree = require("vibing.application.chat.use_cases.cancel_tree")
  end)

  after_each(function()
    Git.get_root = originals.get_root
    view.get_chat_buffer = originals.get_chat_buffer
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
    vim.fn.delete(dir, "rf")
  end)

  it("stops every running chat below the one it was given", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "mid.md" } })
    ChatFiles.write(dir, "mid.md", { orchestrated_by = { "root.md" }, orchestrated = { "leaf.md" } })
    ChatFiles.write(dir, "leaf.md", { orchestrated_by = { "mid.md" } })

    local mid, leaf = open_buffer("mid.md"), open_buffer("leaf.md")
    running = { [mid] = true, [leaf] = true }

    local stopped, visited = CancelTree.execute("mid.md")

    assert.same({ mid, leaf }, cancelled)
    assert.equals(2, #stopped)
    assert.equals(2, visited)
  end)

  it("leaves the chats above the given one alone", function()
    -- 指したノードから下だけを止める、がこのコマンドの意味。上まで巻き込むと自分の親が道連れになる
    ChatFiles.write(dir, "root.md", { orchestrated = { "mid.md" } })
    ChatFiles.write(dir, "mid.md", { orchestrated_by = { "root.md" } })

    local root, mid = open_buffer("root.md"), open_buffer("mid.md")
    running = { [root] = true, [mid] = true }

    CancelTree.execute("mid.md")

    assert.same({ mid }, cancelled)
  end)

  it("counts a chat with nothing running as visited but not cancelled", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "b.md" } })
    ChatFiles.write(dir, "b.md", {})

    local root, b = open_buffer("root.md"), open_buffer("b.md")
    running = { [root] = true }

    local stopped, visited = CancelTree.execute("root.md")

    assert.equals(1, #stopped)
    assert.equals(2, visited)
    assert.same({ root }, cancelled)
    assert.is_not_nil(pending_at_cancel[b])
  end)

  it("drops the delivery queue before it stops anything", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "b.md" } })
    ChatFiles.write(dir, "b.md", { orchestrated_by = { "root.md" } })

    local root, b = open_buffer("root.md"), open_buffer("b.md")
    running = { [root] = true, [b] = true }
    MessageQueue.enqueue_message(b, root, "carry on")
    assert.is_true(MessageQueue.has_pending(b), "precondition")

    CancelTree.execute("root.md")

    assert.is_false(pending_at_cancel[b], "the queue must be gone by the time the turn is killed")
    assert.is_false(MessageQueue.has_pending(b))
  end)

  it("reports nothing to stop for a tree where no chat is open", function()
    ChatFiles.write(dir, "root.md", { orchestrated = { "b.md" } })
    ChatFiles.write(dir, "b.md", {})

    local stopped, visited = CancelTree.execute("root.md")

    assert.equals(0, #stopped)
    assert.equals(2, visited)
  end)
end)
