-- Tests for the chat status an orchestrator polls to tell whether a worker chat is still busy.
-- Also pins buf_get_lines' two return shapes: the MCP server and this plugin install separately,
-- so an older server that sends no include_chat_status must keep getting the bare line array.

local ChatBuffers = require("tests.helpers.chat_buffers")

describe("chat status", function()
  local ChatStatus, BufferHandler, view

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
    ChatStatus = require("vibing.presentation.chat.modules.chat_status")
    BufferHandler = require("vibing.infrastructure.rpc.handlers.buffer")
  end)

  after_each(ChatBuffers.reset)

  it("reports nil for a buffer that is not a vibing chat", function()
    local bufnr = vim.api.nvim_create_buf(false, true)

    assert.is_nil(ChatStatus.get(bufnr))
  end)

  it("reports idle for a chat with no request in flight", function()
    local chat_buf = view.render({ session_id = "idle-session" }, "back")

    assert.equals("idle", ChatStatus.get(chat_buf.buf))
  end)

  it("reports responding while the CLI process is streaming", function()
    local chat_buf = view.render({ session_id = "busy-session" }, "back")
    chat_buf._current_handle_id = "handle-1"

    assert.equals("responding", ChatStatus.get(chat_buf.buf))
  end)

  it("reports responding in the gap between <CR> and the CLI actually starting", function()
    -- _current_handle_id is only set once the adapter spawns; without _is_sending those few
    -- dozen milliseconds read as "finished" and an orchestrator would summarize an empty reply.
    local chat_buf = view.render({ session_id = "sending-session" }, "back")
    chat_buf._is_sending = true

    assert.equals("responding", ChatStatus.get(chat_buf.buf))
  end)

  describe("buf_get_lines", function()
    it("returns the bare line array when no status was asked for", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "a", "b" })

      assert.same({ "a", "b" }, BufferHandler.buf_get_lines({ bufnr = bufnr }))
    end)

    it("wraps lines and status together when asked", function()
      local chat_buf = view.render({ session_id = "wrapped" }, "back")

      local result = BufferHandler.buf_get_lines({ bufnr = chat_buf.buf, include_chat_status = true })

      assert.is_table(result.lines)
      assert.equals("idle", result.chat_status)
    end)

    it("omits the status for a non-chat buffer even when asked", function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "plain" })

      local result = BufferHandler.buf_get_lines({ bufnr = bufnr, include_chat_status = true })

      assert.same({ "plain" }, result.lines)
      assert.is_nil(result.chat_status)
    end)
  end)
end)
