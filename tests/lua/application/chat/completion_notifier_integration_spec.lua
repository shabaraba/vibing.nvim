--- 通知機構を、本物の `ChatBuffer` と本物の autocmd で通す統合spec。
---
--- `completion_notifier_spec.lua` は同じ判定を単体で固定しているが、そちらは
--- `view.get_chat_buffer` / `view.list_chat_buffers` を偽のテーブルに差し替え、
--- `Notifier.on_response_done()` を直接呼ぶ。つまり4つの配線が検証されないまま残る:
---
---   1. `insert_approval_request` が本当に `get_stop_reason()` の読む値を書くか
---   2. `add_user_section()` が本当に `flush` を拒否させる下書きを作るか
---   3. `concurrency` が本物の `is_responding()` で本数を数えられるか
---   4. `Notifier.setup()` が本当に `VibingResponseDone` を購読しているか
---
--- 4 は単体では原理的に取れない。`setup()` は autocmd を `vim.schedule` の中で張るので、
--- 「イベントは撃たれるのに購読者がいない」という壊れ方が起きうる（PR #666 の実機確認で実際に
--- 踏んだ）。ここではイベントを本当に `nvim_exec_autocmds` で撃つことでその層まで通す。
---
--- 差し替えるのは `ProgrammaticSender.send` だけ。配達が通ると本物のCLIターンが走って
--- トークンを使うので、そこで止めて「誰に何が配られようとしたか」を読む。
local Config = require("vibing.config")
local vibing = require("vibing")
local view = require("vibing.presentation.chat.view")
local CreateChat = require("vibing.application.chat.use_cases.create_chat")
local Concurrency = require("vibing.application.chat.concurrency")
local ProgrammaticSender = require("vibing.presentation.chat.modules.programmatic_sender")

describe("CompletionNotifier wiring", function()
  ---モジュールレベルの購読テーブルはspec間で共有されるので、毎回requireし直して捨てる
  local Notifier
  local MessageQueue
  local originals = {}
  local save_dir
  local sends
  local chats

  ---@param max_concurrent number
  local function configure(max_concurrent)
    -- 既定を土台にする。`create_new` / `view.render` は `config.chat` を深く読むので、
    -- 必要なキーだけの手書きテーブルだとそちらが落ちる
    local cfg = vim.tbl_deep_extend("force", vim.deepcopy(Config.defaults), {
      chat = { save_location_type = "custom", save_dir = save_dir },
      agent = {
        -- **既定のまま無効**。自力で抜けられない停止の通知が設定に依らず届くことが主題なので、
        -- ここを有効にしてしまうと watchdog と区別がつかなくなる
        chat_notifications = { enabled = false },
        orchestration = { max_concurrent = max_concurrent },
      },
    })
    -- 読み口が2つある。通知機構と並列度上限は `Config.get()` を、チャット生成と描画は
    -- `vibing.get_config()` を見るので、両方を同じテーブルに向ける
    Config.get = function()
      return cfg
    end
    vibing.get_config = function()
      return cfg
    end
  end

  ---本物のチャットバッファを1つ作る
  ---@return Vibing.ChatBuffer
  local function open_chat()
    local session = CreateChat.execute({})
    -- `background = true` で `view._current_buffer` を奪わない。ワーカーはユーザーが
    -- 開いたものではない（view.lua の同名オプションの注記を参照）
    local chat_buf = view.render(session, "back", { background = true })
    table.insert(chats, chat_buf)
    return chat_buf
  end

  ---ターン終了を本物のイベントとして撃つ
  ---@param chat_buf Vibing.ChatBuffer
  local function finish_turn(chat_buf)
    vim.api.nvim_exec_autocmds("User", { pattern = "VibingResponseDone", data = { bufnr = chat_buf.buf } })
  end

  ---@param chat_buf Vibing.ChatBuffer
  ---@return boolean
  local function was_sent_to(chat_buf)
    for _, sent in ipairs(sends) do
      if sent.bufnr == chat_buf.buf then
        return true
      end
    end
    return false
  end

  before_each(function()
    originals.config_get = Config.get
    originals.get_config = vibing.get_config
    originals.send = ProgrammaticSender.send

    save_dir = vim.fn.tempname()
    vim.fn.mkdir(save_dir, "p")
    sends = {}
    chats = {}
    configure(1)

    ProgrammaticSender.send = function(bufnr, message)
      table.insert(sends, { bufnr = bufnr, message = message })
      return { success = true, bufnr = bufnr }
    end

    package.loaded["vibing.application.chat.message_queue"] = nil
    package.loaded["vibing.application.chat.completion_notifier"] = nil
    Notifier = require("vibing.application.chat.completion_notifier")
    MessageQueue = require("vibing.application.chat.message_queue")
    -- 本物の autocmd を張る。augroup は `clear = true` なので、テストごとに張り直しても
    -- 前のテストのモジュールインスタンスが残ることはない
    Notifier.setup()
  end)

  after_each(function()
    Config.get = originals.config_get
    vibing.get_config = originals.get_config
    ProgrammaticSender.send = originals.send

    for _, chat_buf in ipairs(chats) do
      if vim.api.nvim_buf_is_valid(chat_buf.buf) then
        vim.api.nvim_buf_delete(chat_buf.buf, { force = true })
      end
    end
    vim.fn.delete(save_dir, "rf")
  end)

  it("reports a worker blocked on a tool approval, through the real buffer and the real event", function()
    local parent, worker, leaf, busy = open_chat(), open_chat(), open_chat(), open_chat()

    -- `is_responding()` が読むのはこのフィールド。本当のターンを走らせずに「応答中」を作る
    -- 公開の入口は無いので直接立てる（`send_message()` はCLIを起動してしまう）
    busy._is_sending = true
    assert.is_true(Concurrency.at_capacity(), "the one slot should be taken by the busy chat")

    Notifier.subscribe(parent.buf, worker.buf)
    -- worker 宛に配達待ちを作る。これが `drain` を上限で見送らせる前提になる
    MessageQueue.enqueue_message(worker.buf, leaf.buf, "leaf からの報告")

    worker:insert_approval_request("Bash", { command = "rm -rf /tmp/x" }, { "allow_once", "deny_once" })
    worker:add_user_section()

    -- 配線1と2。単体specでは偽のバッファが返していた値を、ここでは本物が書いている
    assert.equals("waiting_approval", worker:get_stop_reason())
    assert.is_truthy(worker:extract_user_message(), "the approval prompt should sit in the unsent section")

    finish_turn(worker)

    -- 争点。枠が埋まっているので即時配達はできないが、親宛の通知は積まれていなければならない
    assert.is_true(MessageQueue.has_pending(parent.buf), "the parent should have been told")
    assert.equals(0, #sends, "nothing can be delivered while the only slot is taken")

    busy._is_sending = false
    finish_turn(busy)

    assert.is_true(was_sent_to(parent), "the freed slot delivers the notice to the parent")
    assert.is_false(was_sent_to(worker), "the worker is blocked on its draft, so nothing restarts it")
  end)

  it("stays silent for an ordinary stop, since the watchdog is still opt-in", function()
    -- 対になるケース。停止理由が無ければ `chat_notifications.enabled = false` が効く。
    -- これが無いと、上のテストは「無効でも常に配る」だけを示すことになり、フラグが
    -- 何も塞がなくなった場合に気づけない
    local parent, worker = open_chat(), open_chat()

    Notifier.subscribe(parent.buf, worker.buf)
    assert.is_nil(worker:get_stop_reason())

    finish_turn(worker)

    assert.is_false(MessageQueue.has_pending(parent.buf))
    assert.equals(0, #sends)
  end)
end)
