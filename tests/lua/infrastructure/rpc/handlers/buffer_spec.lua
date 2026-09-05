-- `nvim_get_buffer` の宛先解決。送信側（message_spec）と対になる読み取り側で、
-- **同じ引数が別の意味を持つ**のがここの主題。
--
-- `bufnr: 0` は読み取りではカレントバッファ（`nvim_get_buffer` が宣伝しているとおり）、
-- 送信では拒否。`handlers/bufnr.lua` が resolver を2つ持っている理由がこれで、
-- 片方に寄せると読み取りが壊れるか、送信がユーザーの見ているチャットに配達する。
--
-- 実際にチャットファイルを開く挙動そのものは `chat_locator_spec.lua` の担当なので、
-- ここは `ChatLocator.open` をスタブして接合部だけを見る。

local BufferHandler = require("vibing.infrastructure.rpc.handlers.buffer")
local ChatLocator = require("vibing.application.chat.chat_locator")

describe("rpc handlers.buffer.buf_get_lines target resolution", function()
  local original_open
  local buffers = {}

  ---@param lines string[]
  ---@return number bufnr
  local function make_buffer(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    table.insert(buffers, bufnr)
    return bufnr
  end

  before_each(function()
    original_open = ChatLocator.open
    buffers = {}
  end)

  after_each(function()
    ChatLocator.open = original_open
    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("reads the chat a file_path names", function()
    local target = make_buffer({ "## User", "from the named chat" })
    local asked_for
    ChatLocator.open = function(file_path)
      asked_for = file_path
      return target
    end

    local result = BufferHandler.buf_get_lines({
      file_path = ".vibing/chat/worker.md",
      include_chat_status = true,
    })

    assert.equals(".vibing/chat/worker.md", asked_for)
    assert.same({ "## User", "from the named chat" }, result.lines)
  end)

  it("refuses a call that names the target twice instead of picking one", function()
    local target = make_buffer({ "x" })
    ChatLocator.open = function()
      error("should not resolve a path when bufnr was given too")
    end

    assert.has_error(function()
      BufferHandler.buf_get_lines({ bufnr = target, file_path = ".vibing/chat/worker.md" })
    end)
  end)

  it("treats an explicit null file_path as absent, not as a second target", function()
    -- `vim.json.decode` turns a JSON null into `vim.NIL`, which is truthy in Lua
    local target = make_buffer({ "still readable" })

    assert.same({ "still readable" }, BufferHandler.buf_get_lines({ bufnr = target, file_path = vim.NIL }))
  end)

  it("still falls back to the current buffer when given neither", function()
    local target = make_buffer({ "current" })
    vim.api.nvim_set_current_buf(target)

    assert.same({ "current" }, BufferHandler.buf_get_lines({}))
    assert.same({ "current" }, BufferHandler.buf_get_lines(nil))
  end)

  it("reads bufnr 0 as the current buffer, unlike the send path which refuses it", function()
    local target = make_buffer({ "current" })
    vim.api.nvim_set_current_buf(target)

    assert.same({ "current" }, BufferHandler.buf_get_lines({ bufnr = 0 }))
  end)

  describe("the bufnr it reports back", function()
    -- 古い Neovim は `file_path` を無視して `bufnr or 0`（＝カレントバッファ）を返す。
    -- それは指名したチャットの健全なトランスクリプトに見えるので、MCP サーバー側は
    -- 「読んだバッファを名乗ったかどうか」でその状況を検知する。名乗りが常に**実在の番号**で
    -- あることがその判定の前提になる

    it("names the buffer a file_path resolved to", function()
      local target = make_buffer({ "x" })
      ChatLocator.open = function()
        return target
      end

      local result = BufferHandler.buf_get_lines({ file_path = "worker.md", include_chat_status = true })

      assert.equals(target, result.bufnr)
    end)

    it("resolves 0 to a real buffer number rather than echoing the argument", function()
      local target = make_buffer({ "current" })
      vim.api.nvim_set_current_buf(target)

      local result = BufferHandler.buf_get_lines({ bufnr = 0, include_chat_status = true })

      assert.equals(target, result.bufnr)
    end)

    it("is absent from the bare-array shape an older MCP server asks for", function()
      local target = make_buffer({ "x" })

      -- `include_chat_status` 無しの返り値は配列そのもの。ここに名乗りを足すと、
      -- `.join()` を呼ぶ古いサーバーが壊れる
      assert.same({ "x" }, BufferHandler.buf_get_lines({ bufnr = target }))
    end)
  end)

  describe("tail_lines / last_section / total_lines (#694)", function()
    it("windows to the last N lines and reports the buffer's real total", function()
      local target = make_buffer({ "1", "2", "3", "4", "5" })

      local result = BufferHandler.buf_get_lines({
        bufnr = target,
        include_chat_status = true,
        tail_lines = 2,
      })

      assert.same({ "4", "5" }, result.lines)
      assert.equals(5, result.total_lines)
    end)

    it("windows to the last '## ...' section", function()
      local target = make_buffer({
        "## User <!-- 2026-01-01 00:00:00 -->",
        "first",
        "## Assistant <!-- 2026-01-01 00:00:01 -->",
        "second",
      })

      local result = BufferHandler.buf_get_lines({
        bufnr = target,
        include_chat_status = true,
        last_section = true,
      })

      assert.same({ "## Assistant <!-- 2026-01-01 00:00:01 -->", "second" }, result.lines)
      assert.equals(4, result.total_lines)
    end)

    it("reports total_lines even when the whole buffer was read", function()
      local target = make_buffer({ "a", "b" })

      local result = BufferHandler.buf_get_lines({ bufnr = target, include_chat_status = true })

      assert.same({ "a", "b" }, result.lines)
      assert.equals(2, result.total_lines)
    end)

    it("windows even in the bare-array shape, since only the response shape is opt-in", function()
      -- include_chat_status and tail_lines/last_section are independent: an older MCP server
      -- that never sends tail_lines is unaffected, but a caller that does ask for a window gets
      -- one whether or not it also asked to be wrapped with chat status.
      local target = make_buffer({ "1", "2", "3" })

      assert.same({ "3" }, BufferHandler.buf_get_lines({ bufnr = target, tail_lines = 1 }))
    end)

    it("still returns the untouched bare array when no window was asked for", function()
      local target = make_buffer({ "1", "2", "3" })

      assert.same({ "1", "2", "3" }, BufferHandler.buf_get_lines({ bufnr = target }))
    end)
  end)
end)
