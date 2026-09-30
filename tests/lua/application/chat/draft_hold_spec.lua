-- 下書きに塞がれた配達の配り直し（#831）。
--
-- `flush` が見送る理由は2つあるが、解ける合図を持たないのは下書きだけ。宛先が応答中なら
-- そのチャット自身のターン終了が `flush` を呼び直すので、ここが見張るのは下書きのほうだけになる。
-- 配線（`flush` がいつ `watch` / `forget` を呼ぶか）は message_queue_spec が見る。
local view = require("vibing.presentation.chat.view")
local notify = require("vibing.core.utils.notify")
local MessageQueue = require("vibing.application.chat.message_queue")
local CompletionNotifier = require("vibing.application.chat.completion_notifier")

describe("DraftHold", function()
  local DraftHold
  local originals = {}
  local buffers = {}
  local responding = {}
  local drafts = {}
  local pending = {}
  local infos = {}
  local retries = {}
  local draft_reads = {}

  ---@return number bufnr
  local function make_chat()
    local bufnr = vim.api.nvim_create_buf(false, true)
    table.insert(buffers, bufnr)
    pending[bufnr] = true
    return bufnr
  end

  ---@param bufnr number
  local function fire_text_changed(bufnr)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  end

  ---`vim.schedule` 済みの配り直しが走りきるまで待つ
  local function settle()
    vim.wait(200, function()
      return false
    end, 10)
  end

  before_each(function()
    originals.get_chat_buffer = view.get_chat_buffer
    originals.info = notify.info
    originals.has_pending = MessageQueue.has_pending
    originals.retry_delivery = CompletionNotifier.retry_delivery

    buffers, responding, drafts, pending = {}, {}, {}, {}
    infos, retries, draft_reads = {}, {}, {}

    view.get_chat_buffer = function(bufnr)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
      end
      return {
        is_responding = function()
          return responding[bufnr] == true
        end,
        extract_user_message = function()
          table.insert(draft_reads, bufnr)
          return drafts[bufnr]
        end,
      }
    end
    notify.info = function(message, title)
      table.insert(infos, { message = message, title = title })
    end
    MessageQueue.has_pending = function(bufnr)
      return pending[bufnr] == true
    end
    CompletionNotifier.retry_delivery = function(bufnr)
      table.insert(retries, bufnr)
      return false
    end

    package.loaded["vibing.application.chat.draft_hold"] = nil
    DraftHold = require("vibing.application.chat.draft_hold")
  end)

  after_each(function()
    for _, bufnr in ipairs(buffers) do
      DraftHold.forget(bufnr)
    end

    view.get_chat_buffer = originals.get_chat_buffer
    notify.info = originals.info
    MessageQueue.has_pending = originals.has_pending
    CompletionNotifier.retry_delivery = originals.retry_delivery

    for _, bufnr in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end
  end)

  it("tells the user once that a delivery is waiting behind their draft", function()
    local a = make_chat()
    drafts[a] = "half a thought"

    DraftHold.watch(a, 2)

    assert.is_true(DraftHold.is_watching(a))
    assert.equals(1, #infos)
    assert.equals("Chat Delivery", infos[1].title)
    assert.is_truthy(infos[1].message:find("2 message", 1, true), "the count belongs in the message: " .. infos[1].message)
  end)

  it("says nothing the second time the same draft holds the same delivery back", function()
    local a = make_chat()
    drafts[a] = "half a thought"

    DraftHold.watch(a, 1)
    DraftHold.watch(a, 1)

    assert.equals(1, #infos, "a warning on every refusal is how the ones that matter get trained away")
  end)

  it("delivers as soon as the draft is cleared, with no send of the user's own", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    drafts[a] = nil
    fire_text_changed(a)
    settle()

    assert.equals(1, #retries)
    assert.equals(a, retries[1])
  end)

  it("keeps waiting while the draft is still there", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    drafts[a] = "half a thought, still"
    fire_text_changed(a)
    settle()

    assert.equals(0, #retries)
    assert.is_true(DraftHold.is_watching(a))
  end)

  it("never reads the draft while the chat is responding", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    -- ストリーミング中はレンダラがバッファを書き換えるので TextChanged が連続発火する。
    -- `extract_user_message` はバッファ全行を読んで最後のユーザーセクションまで遡るので、
    -- 応答中の判定がその手前に無いと長いチャットで変更1回ごとに全行走査が走る
    responding[a] = true
    drafts[a] = nil
    fire_text_changed(a)
    fire_text_changed(a)
    settle()

    assert.equals(0, #retries)
    assert.equals(0, #draft_reads, "the responding check must come before the buffer-wide scan")
  end)

  it("collapses several changes in one tick into a single retry", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    drafts[a] = nil
    fire_text_changed(a)
    fire_text_changed(a)
    fire_text_changed(a)
    settle()

    assert.equals(1, #retries)
  end)

  it("stops watching once the queue was delivered by another route", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    -- 宛先自身のターン終了が先に配り終えた場合。監視の役目は済んでいる
    pending[a] = nil
    fire_text_changed(a)
    settle()

    assert.equals(0, #retries)
    assert.is_false(DraftHold.is_watching(a))
  end)

  it("fires nothing after forget, so a deleted chat is never delivered into", function()
    local a = make_chat()
    drafts[a] = "half a thought"
    DraftHold.watch(a, 1)

    DraftHold.forget(a)
    assert.is_false(DraftHold.is_watching(a))

    drafts[a] = nil
    fire_text_changed(a)
    settle()

    assert.equals(0, #retries)
  end)

  it("watches each holding chat separately", function()
    local a, b = make_chat(), make_chat()
    drafts[a], drafts[b] = "a draft", "another draft"

    DraftHold.watch(a, 1)
    DraftHold.watch(b, 1)
    assert.equals(2, #infos)

    drafts[a] = nil
    fire_text_changed(a)
    settle()

    assert.same({ a }, retries, "B's draft is still in the way")
    assert.is_true(DraftHold.is_watching(b))
  end)
end)
