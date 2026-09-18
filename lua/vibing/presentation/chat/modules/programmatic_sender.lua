---@class Vibing.Presentation.ProgrammaticSender
---Programmatic message sending to chat buffers
local M = {}

local view = require("vibing.presentation.chat.view")
local Renderer = require("vibing.presentation.chat.modules.renderer")
local Timestamp = require("vibing.core.utils.timestamp")
local ConversationExtractor = require("vibing.presentation.chat.modules.conversation_extractor")

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
---応答中のチャットに許される配達は1種類だけ: **そのチャットがいま止めている問い合わせへの答え**。
---それが承認（#778）か質問（#788）かで、下の2つの述語に分かれる
---
---承認をプロセスを殺さずに答えられるようになった以上（#778）、フックがブロックしているワーカーは
---`is_responding()` が true を返し続ける。下のガードをそのまま効かせると、そのワーカーへの
---代理承認（`nvim_chat_answer_approval`）は**この機能が存在する経路でだけ**必ず弾かれる。
---
---**質問も同じ穴に落ちる（#788）。** その場で答えられるようにした時点で質問待ちのターンも開いた
---ままになり、`asked_question` を検知したオーケストレーターの `nvim_chat_send_message` は
---ここで必ず弾かれるようになった — 検知はできるのに答えられない。ワーカー停止通知が案内している
---手順そのものが通らないので、**片方だけ例外を開けたことが、もう片方を塞いだ**
---
---例外の条件は「プロンプトが描いてある」ではなく「**フックが実際に止まっている**」。描いてある
---だけのプロンプト（kill されたターンの残りで、答えれば新しいターンになる）に応答中のチャットで
---答えると、`send_message` は `retry_as_new_turn` に倒れて `cancel_request` を走らせる — つまり
---いま動いているターンを殺す。このガードが本来防いでいるものそのものになる
---@param opts table?
---@return boolean
local function answers_blocked_approval(opts)
  local request_id = opts and opts.answers_blocked_approval
  if type(request_id) ~= "string" or request_id == "" then
    return false
  end
  return require("vibing.infrastructure.rpc.pending_approvals").get(request_id) ~= nil
end

---このチャットがいま答えを待っている質問で止まっているか
---
---`is_responding` の隣にあるが、**別の問い**である点はあちらと同じ。`is_responding` が答えるのは
---「待てば送れるようになるか」で、こちらが答えるのは「**待つと悪化するか**」。質問待ちのチャットは
---`question_wait_sec`（既定900秒）待ったあと `deny` で期限切れになるので、答えをキューに積むのは
---答えないのとほぼ同じことになる
---@param bufnr number
---@return boolean
function M.has_blocked_question(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return require("vibing.infrastructure.rpc.pending_questions").has_for_chat(bufnr)
end

---承認と対称の例外。ただし `request_id` を取らない
---
---承認側が id を要求しているのは「描いてあるだけのプロンプト」と「実際に止まっているフック」を
---区別するためで、**質問ではその区別が別の場所に付いている** — 描いてあるだけのものは
---`_pending_choices` に残り、実際に答えを withhold しているものだけが `pending_questions` に
---載る。レジストリに1件でもあれば必ず誰かが答えを待っているので、id は弱い条件を強い条件に
---変えるためには要らない。
---
---それでも opts のフラグを要求するのは、**呼び出し元を絞るため**。auto_compact の `/compact`、
---auto_resume の再送、`append_notice` はどれも `validate` を通るが、そのどれかが質問待ちの
---チャットに通ってしまうと、その本文が `_answer_pending_question` に答えとして食われる
---@param bufnr number
---@param opts table?
---@return boolean
local function answers_blocked_question(bufnr, opts)
  if not (opts and opts.answers_blocked_question) then
    return false
  end
  return M.has_blocked_question(bufnr)
end

---@param bufnr number
---@param message string
---@param opts? {answers_blocked_approval?: string, answers_blocked_question?: boolean}
---  このメッセージが答えである保留を名指しする。承認は `request_id`、質問は真偽値（上記参照）
---@return table chat_buf
function M.validate(bufnr, message, opts)
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
  if
    chat_buf:is_responding()
    and not answers_blocked_approval(opts)
    and not answers_blocked_question(bufnr, opts)
  then
    error("Chat buffer is already responding")
  end

  if _send_locks[bufnr] then
    error("Another send operation is in progress for this buffer")
  end

  return chat_buf
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

  local chat_buf = M.validate(bufnr, message, opts)

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
    ConversationExtractor.drop_trailing_unsent_section(bufnr, opts.replace_unsent)
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

---Append a timestamped Notice without starting an LLM turn.
---The caller must wait until the chat is idle; this guard keeps a completion event from editing
---the same buffer while streaming output is still arriving.
---@param bufnr number
---@param message string
---@return {success: boolean, bufnr: number}
function M.append_notice(bufnr, message)
  local chat_buf = M.validate(bufnr, message)
  _send_locks[bufnr] = true

  local success, err = pcall(function()
    ConversationExtractor.drop_trailing_unsent_section(bufnr)
    Renderer.addUserSection(bufnr, nil, nil, nil, message, Timestamp.create_header("Notice", Timestamp.now()))
    Renderer.addUserSection(bufnr)
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! write")
    end)
    if vim.bo[bufnr].modified then
      error("the chat buffer could not be saved")
    end
  end)
  _send_locks[bufnr] = nil

  if not success then
    error(string.format("Failed to append notice: %s", tostring(err)))
  end
  return { success = true, bufnr = bufnr }
end

return M
