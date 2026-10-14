-- `:VibingSummarize [--with-title] [--linked]` の引数解釈と、タイトル生成への連鎖を固定する。
--
-- 連鎖で押さえたいのは「どのバッファに対して」タイトルを付けるか。要約は非同期なので、
-- 完了時点のカレントバッファは別のチャット（あるいは非チャット）になっていることがある。
-- そのため `M.handle_set_file_title()`（カレントを取り直す）ではなくハンドラを直接呼び、
-- 要約開始時に掴んだバッファを渡している。ここを取り直す実装に戻すとテストが落ちる。
--
-- `on_done` は常に渡る。`--linked` の逐次実行が完了通知を購読で繋いでいるので、
-- 「何もしない」も1つの後続として扱われる。観測できる契約はタイトルが生成されないこと。

local controller = require("vibing.presentation.chat.controller")

describe("controller.handle_summarize", function()
  local titled_buffers
  local summarized_buffers
  local current_buffer

  ---@param ok boolean 要約が成功したことにするか
  local function stub_use_case(ok)
    package.loaded["vibing.application.chat.use_case"] = {
      generate_and_insert_summary = function(chat_buffer, opts)
        table.insert(summarized_buffers, chat_buffer)
        if opts and opts.on_done then
          opts.on_done(ok, ok and nil or "stubbed failure")
        end
      end,
    }
  end

  before_each(function()
    titled_buffers = {}
    summarized_buffers = {}
    current_buffer = { name = "chat-a", file_path = "/chats/chat-a.md" }

    package.loaded["vibing.presentation.chat.view"] = {
      get_current = function()
        return current_buffer
      end,
    }
    package.loaded["vibing.application.chat.handlers.set_file_title"] = function(_, chat_buffer, opts)
      table.insert(titled_buffers, chat_buffer)
      if opts and opts.on_done then
        opts.on_done(true)
      end
      return true
    end
    stub_use_case(true)
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded["vibing.application.chat.use_case"] = nil
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
  end)

  it("does not generate a title without the flag", function()
    controller.handle_summarize("")

    assert.equals(1, #summarized_buffers)
    assert.equals(0, #titled_buffers)
  end)

  it("treats a missing argument the same as an empty one", function()
    controller.handle_summarize(nil)

    assert.equals(1, #summarized_buffers)
    assert.equals(0, #titled_buffers)
  end)

  it("generates a title after a successful summary with --with-title", function()
    controller.handle_summarize("--with-title")

    assert.equals(1, #titled_buffers)
    assert.equals(current_buffer, titled_buffers[1])
  end)

  it("titles the buffer it started on, not whatever is current when the summary lands", function()
    -- 要約中にユーザーが別のチャットへ移った状況。get_current が別のバッファを返すように
    -- なっても、タイトルは要約したバッファに付かなければならない。
    local started_on = current_buffer
    package.loaded["vibing.application.chat.use_case"] = {
      generate_and_insert_summary = function(chat_buffer, opts)
        table.insert(summarized_buffers, chat_buffer)
        current_buffer = { name = "chat-b" }
        opts.on_done(true)
      end,
    }

    controller.handle_summarize("--with-title")

    assert.equals(1, #titled_buffers)
    assert.equals(started_on, titled_buffers[1])
  end)

  it("skips title generation when the summary failed", function()
    -- summary が無いまま走らせるとタイトル生成は抜粋にフォールバックし、ユーザーが
    -- 頼んでいない API 呼び出しが1回余分に走る。
    stub_use_case(false)

    controller.handle_summarize("--with-title")

    assert.equals(0, #titled_buffers)
  end)

  it("summarizes anyway when given an unknown argument", function()
    controller.handle_summarize("--foo")

    assert.equals(1, #summarized_buffers)
    assert.equals(0, #titled_buffers)
  end)

  it("accepts --with-title alongside an unknown argument", function()
    controller.handle_summarize("--foo --with-title")

    assert.equals(1, #summarized_buffers)
    assert.equals(1, #titled_buffers)
  end)

  it("does nothing outside a chat buffer", function()
    current_buffer = nil

    controller.handle_summarize("--with-title")

    assert.equals(0, #summarized_buffers)
    assert.equals(0, #titled_buffers)
  end)

  -- `--linked` の検査は入れ子の describe にしない。plenary の busted 実装は入れ子にした
  -- before_each を走らせないので、スタブが入らないまま本物の `linked_chats` が呼ばれ、
  -- 「リンク先が0件だった」と区別の付かない緑になる
  local function stub_linked_chats(collected)
    package.loaded["vibing.application.chat.linked_chats"] = {
      collect = function(file_path)
        table.insert(collected, file_path)
        return {}
      end,
    }
  end

  it("does not look for linked chats without --linked", function()
    local collected = {}
    stub_linked_chats(collected)

    controller.handle_summarize("--with-title")
    package.loaded["vibing.application.chat.linked_chats"] = nil

    assert.equals(0, #collected)
  end)

  it("looks for linked chats with --linked", function()
    local collected = {}
    stub_linked_chats(collected)

    controller.handle_summarize("--linked")
    package.loaded["vibing.application.chat.linked_chats"] = nil

    assert.same({ "/chats/chat-a.md" }, collected)
    assert.equals(1, #summarized_buffers)
  end)

  it("combines --linked with --with-title", function()
    local collected = {}
    stub_linked_chats(collected)

    controller.handle_summarize("--with-title --linked")
    package.loaded["vibing.application.chat.linked_chats"] = nil

    assert.equals(1, #collected)
    assert.equals(1, #titled_buffers)
  end)
end)

describe("controller.handle_set_file_title", function()
  local titled_buffers
  local collected
  local current_buffer

  before_each(function()
    titled_buffers = {}
    collected = {}
    current_buffer = { name = "chat-a", file_path = "/chats/chat-a.md" }

    package.loaded["vibing.presentation.chat.view"] = {
      is_current_buffer_chat = function()
        return current_buffer ~= nil
      end,
      get_current = function()
        return current_buffer
      end,
    }
    package.loaded["vibing.application.chat.handlers.set_file_title"] = function(_, chat_buffer, opts)
      table.insert(titled_buffers, chat_buffer)
      if opts and opts.on_done then
        opts.on_done(true)
      end
      return true
    end
    package.loaded["vibing.application.chat.linked_chats"] = {
      collect = function(file_path)
        table.insert(collected, file_path)
        return {}
      end,
    }
  end)

  after_each(function()
    package.loaded["vibing.presentation.chat.view"] = nil
    package.loaded["vibing.application.chat.handlers.set_file_title"] = nil
    package.loaded["vibing.application.chat.linked_chats"] = nil
  end)

  it("renames only this chat with no argument", function()
    controller.handle_set_file_title(nil)

    assert.equals(1, #titled_buffers)
    assert.equals(0, #collected)
  end)

  it("looks for linked chats with --linked", function()
    controller.handle_set_file_title("--linked")

    assert.equals(1, #titled_buffers)
    assert.same({ "/chats/chat-a.md" }, collected)
  end)

  it("never summarizes — the title is the whole command", function()
    -- `:VibingSetFileTitle` に要約は含まれない。含めると、ユーザーが頼んでいない
    -- API 呼び出しが1チャットにつき1回余分に走る
    local summarized = 0
    package.loaded["vibing.application.chat.use_case"] = {
      generate_and_insert_summary = function()
        summarized = summarized + 1
      end,
    }

    controller.handle_set_file_title("--linked")
    package.loaded["vibing.application.chat.use_case"] = nil

    assert.equals(0, summarized)
  end)
end)
