-- `:VibingChatHandoff [position]`: 要約は非同期なので、完了時のカレントバッファではなく
-- 開始時に掴んだバッファを最後まで使い、返ってきた session を指定位置に描画する。
local controller = require("vibing.presentation.chat.controller")

describe("controller.handle_handoff", function()
  local rendered
  local executed
  local current_buffer

  before_each(function()
    rendered = {}
    executed = {}
    current_buffer = { name = "chat-a" }

    package.loaded["vibing.presentation.chat.view"] = {
      get_current = function()
        return current_buffer
      end,
      render = function(session, position)
        table.insert(rendered, { session = session, position = position })
        return { win = nil, buf = nil }
      end,
    }
    package.loaded["vibing.application.chat.use_cases.handoff"] = {
      execute = function(chat_buffer, opts)
        table.insert(executed, { chat_buffer = chat_buffer, opts = opts })
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded["vibing.application.chat.use_cases.handoff"] = nil
  end)

  it("renders the handoff session at the requested position", function()
    controller.handle_handoff("right")

    assert.equals(1, #executed)
    assert.equals(current_buffer, executed[1].chat_buffer)

    local session = {
      get_file_path = function()
        return "/tmp/x-handoff-1.md"
      end,
    }
    executed[1].opts.on_done(session)

    assert.equals(1, #rendered)
    assert.equals(session, rendered[1].session)
    assert.equals("right", rendered[1].position)
  end)

  it("passes no position when none was given", function()
    controller.handle_handoff("")
    executed[1].opts.on_done({
      get_file_path = function()
        return "x.md"
      end,
    })

    assert.is_nil(rendered[1].position)
  end)

  it("renders nothing when the handoff failed", function()
    controller.handle_handoff(nil)
    executed[1].opts.on_done(nil, "failed")

    assert.equals(0, #rendered)
  end)

  it("does nothing outside a chat buffer", function()
    current_buffer = nil
    controller.handle_handoff("right")

    assert.equals(0, #executed)
    assert.equals(0, #rendered)
  end)
end)
