-- Tests for the chat status an orchestrator polls to tell whether a worker chat is still busy.
-- Also pins buf_get_lines' two return shapes: the MCP server and this plugin install separately,
-- so an older server that sends no include_chat_status must keep getting the bare line array.

local ChatBuffers = require("tests.helpers.chat_buffers")

describe("chat status", function()
  local ChatStatus, BufferHandler, view, Registry

  before_each(function()
    ChatBuffers.setup()
    view = require("vibing.presentation.chat.view")
    ChatStatus = require("vibing.presentation.chat.modules.chat_status")
    BufferHandler = require("vibing.infrastructure.rpc.handlers.buffer")
    Registry = require("vibing.infrastructure.adapter.modules.active_stream_registry")
  end)

  after_each(function()
    ChatBuffers.reset()
    Registry.unregister("handle-1")
    Registry.unregister("handle-2")
  end)

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
    Registry.register({ handle_id = "handle-1", adapter = {} })

    assert.equals("responding", ChatStatus.get(chat_buf.buf))
  end)

  it("reports idle once the stream ended, even though the handle id is still set", function()
    -- send_message.lua deliberately never clears _current_handle_id: the next send uses it to
    -- kill a process that outlived its own result event. Read as a boolean it would pin every
    -- chat at "responding" from its first turn onward, which is the one answer a polling
    -- orchestrator can never recover from. The registry is what actually knows the run is over.
    local chat_buf = view.render({ session_id = "finished-session" }, "back")
    chat_buf._current_handle_id = "handle-2"
    Registry.register({ handle_id = "handle-2", adapter = {} })
    Registry.unregister("handle-2")

    assert.equals("idle", ChatStatus.get(chat_buf.buf))
  end)

  it("reports responding in the gap between <CR> and the CLI actually starting", function()
    -- _current_handle_id is only set once the adapter spawns; without _is_sending those few
    -- dozen milliseconds read as "finished" and an orchestrator would summarize an empty reply.
    local chat_buf = view.render({ session_id = "sending-session" }, "back")
    chat_buf._is_sending = true

    assert.equals("responding", ChatStatus.get(chat_buf.buf))
  end)

  describe("why the chat stopped", function()
    -- `idle` は「リクエストが飛んでいない」だけなので、失敗・質問待ち・承認待ちを区別できない。
    -- `completion_notifier` の分岐2はこれを例外条件の材料に使う（#640）

    it("reports asked_question and survives add_user_section clearing the choices", function()
      -- 理由は `_pending_choices` のスナップショットではないので、それが消えても残る
      local chat_buf = view.render({ session_id = "asked" }, "back")
      chat_buf:insert_choices({ { question = "which?", options = { { label = "a" } } } })

      chat_buf:add_user_section()

      assert.is_nil(chat_buf._pending_choices)
      assert.equals("asked_question", ChatStatus.get(chat_buf.buf))
    end)

    it("reports waiting_approval while a tool approval prompt is unanswered", function()
      local chat_buf = view.render({ session_id = "approval" }, "back")
      chat_buf:insert_approval_request("Bash", { command = "ls" }, { "allow_once" }, "req-1")

      assert.equals("waiting_approval", ChatStatus.get(chat_buf.buf))
    end)

    it("reports error for a turn that ended with one", function()
      local chat_buf = view.render({ session_id = "failed" }, "back")
      chat_buf:mark_turn_error()

      assert.equals("error", ChatStatus.get(chat_buf.buf))
    end)

    it("clears the previous turn's reason when a new turn actually starts", function()
      -- 停止理由が居座ると、動き出したチャットが前のターンの理由で保留を外れ続ける
      local chat_buf = view.render({ session_id = "recovered" }, "back")
      chat_buf:mark_turn_error()
      assert.equals("error", ChatStatus.get(chat_buf.buf))

      vim.api.nvim_buf_set_lines(chat_buf.buf, -1, -1, false, { "carry on" })
      chat_buf:send_message()

      assert.is_nil(chat_buf:get_stop_reason())
    end)

    it("keeps the reason when the send is refused before a turn starts", function()
      -- 空の `## User` での <CR>、スラッシュコマンド、承認応答のパース失敗などは途中 return する。
      -- そこで理由を消すと、まだ承認を待っているチャットが idle に化けて通知の保留も外れる
      local chat_buf = view.render({ session_id = "still-blocked" }, "back")
      chat_buf:insert_approval_request("Bash", { command = "ls" }, { "allow_once" }, "req-1")

      assert.is_false(chat_buf:send_message())

      assert.equals("waiting_approval", ChatStatus.get(chat_buf.buf))
    end)

    it("reports responding rather than the old reason while a turn is in flight", function()
      local chat_buf = view.render({ session_id = "busy-after-error" }, "back")
      chat_buf:mark_turn_error()
      chat_buf._is_sending = true

      assert.equals("responding", ChatStatus.get(chat_buf.buf))
    end)
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
