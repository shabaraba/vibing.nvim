---@class Vibing.Presentation.ProgrammaticSender
---Programmatic message sending to chat buffers
local M = {}

local view = require("vibing.presentation.chat.view")
local Renderer = require("vibing.presentation.chat.modules.renderer")
local Timestamp = require("vibing.core.utils.timestamp")

-- Per-buffer send locks to prevent concurrent sends
local _send_locks = {}

---いま新しいメッセージを受け付けられない状態か
---
---`validate` の一部を述語として切り出したのではなく、**別の問い**を立てている。呼び出し元が
---知りたいのは「待てば送れるようになるか」で、その答えが yes なのは応答中のときだけ。
---無効なバッファも空メッセージも待って解けるものではないので、それらは `validate` の
---エラーのままでよい（`nvim_chat_send_message` の `queue_if_busy`）。
---
---エラーメッセージの文字列一致で代用させないために公開している。文言を直した日に、
---キューが黙って効かなくなる
---@param bufnr number
---@return boolean
function M.is_responding(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local chat_buf = view.get_chat_buffer(bufnr)
  return chat_buf ~= nil and chat_buf:is_responding()
end

---送信できる状態かを確かめ、対象のChatBufferを返す（送れないなら error）
---
---`send`から切り出してあるのは、送信の前に別の副作用を済ませたい呼び出し元があるため。
---`nvim_chat_send_message`はfrontmatterへのリンク書き込みを送信より前に行う必要がある
---（バッファを直接触るので、応答が始まってから書くとストリーミングと競合する）ので、
---「書いたあとに送信が弾かれ、行われなかったやり取りの関係だけが残る」のを避けるには
---先にここを通す必要がある
---@param bufnr number
---@param message string
---@return table chat_buf
function M.validate(bufnr, message)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    error("Invalid buffer number")
  end

  if not message or vim.trim(message) == "" then
    error("Empty message")
  end

  local chat_buf = view.get_chat_buffer(bufnr)
  if not chat_buf then
    error("Buffer is not a vibing chat buffer")
  end

  -- 応答中のバッファには積まない。`ChatBuffer:send_message()` は `_is_sending` を見て
  -- **黙って return** するので、先に `addUserSection` してしまうと送られない `## User`
  -- セクションがバッファに残り、次にユーザーが<CR>したときの本文に化ける。さらにその手前で
  -- 「前のリクエストが実行中ならキャンセル」が走るため、進行中のターンごと殺しうる。
  -- 追加してから巻き戻すのではなく、追加する前に断る。
  --
  -- `send` 本体ではなくここに置くことで、リンク書き込みの前に呼ぶ事前検証でも同じ判定が効く
  if chat_buf:is_responding() then
    error("Chat buffer is already responding")
  end

  if _send_locks[bufnr] then
    error("Another send operation is in progress for this buffer")
  end

  return chat_buf
end

---末尾の未送信セクションを落とす（既定では中身が空のときだけ）
---
---ターンが終わるたび `add_user_section()` が空の `## User <!-- unsent -->` を置く。人間はそこに
---打ち込むのでセクションは1つのままだが、配達はその下に**もう1つ**足していたので、配達された
---ターンの上には毎回空の User セクションが取り残されていた（実際のオーケストレーションで
---1ターンにつき1つ増えるのを確認）。
---
---落とすのは中身が空のときだけ。承認プロンプトや質問の選択肢は同じ未送信セクションに
---描かれるので、それらは「空でない」として残る（`replace_unsent` を渡した呼び出しを除く）。
---
---@param buf number
---@param replace_unsent boolean? true なら中身があっても末尾の未送信セクションを落とす。
---  承認への代理応答（`approval_delegate`）専用で、そこでは承認プロンプトそのものが
---  「置き換える対象」になる。残すと、答え終わったプロンプトがバッファに永久に居座る
local function drop_trailing_unsent_section(buf, replace_unsent)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  -- 末尾から空行を飛ばして最初に当たった行がヘッダーなら、それが最後のセクションで、かつ
  -- 中身は空。ヘッダー行が空行であることはないので、この1走査が「最後のヘッダー」と
  -- 「その下は空」の両方を同時に確かめている
  local last = #lines
  while last > 0 and vim.trim(lines[last]) == "" do
    last = last - 1
  end

  if last == 0 then
    return
  end

  if not Timestamp.is_unsent_header(lines[last]) then
    if not replace_unsent then
      return
    end
    -- 中身のある未送信セクションを落とす経路。末尾から**最初に当たったヘッダー**まで戻り、
    -- それが未送信でなければ何もしない。「未送信ヘッダーを見つけるまで遡る」にすると、
    -- 送信済みセクションを飛び越えて上のほうの未送信セクションを消しうる
    repeat
      last = last - 1
    until last == 0 or Timestamp.is_header(lines[last])
    if last == 0 or not Timestamp.is_unsent_header(lines[last]) then
      return
    end
  end

  -- ヘッダーの手前の空行も一緒に落とす。残しても `addUserSection` が末尾の空行を畳むが、
  -- 畳む対象を残したまま返すと「何を消したか」が2箇所に分かれる
  local first = last
  while first > 1 and vim.trim(lines[first - 1]) == "" do
    first = first - 1
  end
  vim.api.nvim_buf_set_lines(buf, first - 1, #lines, false, {})
end

---@param bufnr number
---@param message string
---@param sender string?
---@param delivery Vibing.Application.DeliveryMessage.Section? 他のチャットからの配達なら、
---  そのセクション見出しに使う種別と送信元。省略すると通常の `## User` セクションになる
---@param opts {replace_unsent: boolean?}? `replace_unsent` で、中身のある末尾の未送信
---  セクションも落としてから書く（承認プロンプトへの代理応答）
function M.send(bufnr, message, sender, delivery, opts)
  sender = sender or "User"
  opts = opts or {}

  local chat_buf = M.validate(bufnr, message)

  -- Acquire lock to prevent concurrent sends
  _send_locks[bufnr] = true

  local sent = false
  local success, err = pcall(function()
    -- Save and restore cursor position
    local saved_win = vim.api.nvim_get_current_win()
    local saved_cursor = vim.api.nvim_win_is_valid(saved_win)
      and vim.api.nvim_win_get_cursor(saved_win)
      or nil

    -- Add user section and send
    local header = delivery and Timestamp.create_header(delivery.kind, nil, delivery.from) or nil
    drop_trailing_unsent_section(bufnr, opts.replace_unsent)
    Renderer.addUserSection(bufnr, nil, nil, nil, message, header)
    sent = chat_buf:send_message()

    -- Restore cursor
    if saved_cursor and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_win_set_cursor, saved_win, saved_cursor)
    end
  end)

  -- Release lock
  _send_locks[bufnr] = nil

  if not success then
    error(string.format("Failed to send message: %s", tostring(err)))
  end

  return { success = sent, bufnr = bufnr }
end

return M
