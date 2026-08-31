---@class Vibing.Application.DeliveryMessage
---`message_queue` が溜めたものを、受け取るチャットに読ませる1通のテキストにする。
---
---キューの状態機械とは別モジュールにしてある。ここにあるのはモデルに読ませる散文であって、
---待ち合わせの規則ではない — 文面の推敲で配達の順序が変わることはないし、その逆もない。
local M = {}

---@param bufnr number
---@param cache table<number, string>
---@return string
local function display_path(bufnr, cache)
  if cache[bufnr] then
    return cache[bufnr]
  end

  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  -- frontmatter の `orchestrated` と同じ表示形式にする。モデルが読みに行く先を、
  -- 記録と別の形で名指ししない
  local path = name ~= "" and require("vibing.core.utils.git").to_display_path(name) or "unnamed"

  -- `to_display_path` は解決を `git rev-parse` に投げ、それはキャッシュを持たない同期の
  -- プロセス起動。1通に同じチャットが複数回現れるのは普通（同じ相手からの複数の報告）なので、
  -- 1通を組み立てる間だけ覚える。バッファ名は改名されうるので、それ以上は持ち越さない
  cache[bufnr] = path
  return path
end

---@param items Vibing.Application.MessageQueue.Item[]
---@param cache table<number, string>
---@return string
local function notification_section(items, cache)
  -- パスを先に置くのはシステムプロンプトの orchestrator 行と同じ理由で、再起動を跨いで
  -- 意味を保つのはパスのほうだから（#641）
  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, string.format("- %s (chat buffer %d)", display_path(item.bufnr, cache), item.bufnr))
  end

  return table.concat({
    "The following chat(s) you sent a message to have finished responding:",
    "",
    table.concat(lines, "\n"),
    "",
    "Read each one with nvim_get_buffer({ rpc_port, file_path }) and decide what to do next.",
    "",
    '"Finished" only means no request is in flight. A chat may have failed, stopped to ask the',
    "user something, or be waiting on a tool approval. Read the tail of the transcript before",
    "treating its task as done.",
    "",
    "If other chats you dispatched are still running, do not start aggregating yet — say what",
    "this one produced and end the turn. You will be woken again when the next one finishes.",
  }, "\n")
end

---@param items Vibing.Application.MessageQueue.Item[]
---@param cache table<number, string>
---@return string
local function message_section(items, cache)
  local blocks = {}
  for _, item in ipairs(items) do
    local from = item.bufnr and string.format("%s (chat buffer %d)", display_path(item.bufnr, cache), item.bufnr)
      or "another chat"
    table.insert(blocks, string.format("### From %s\n\n%s", from, item.body))
  end

  -- 件数はメッセージの数であってチャットの数ではない。1つのワーカーからの2件を
  -- 「2つのチャットから」と言うと、読み手は出どころを取り違える
  return table.concat({
    #blocks == 1 and "Another chat sent you this while you were responding:"
      or string.format("%d messages arrived while you were responding:", #blocks),
    "",
    table.concat(blocks, "\n\n"),
  }, "\n")
end

---溜まったものを1通にまとめる
---
---通知だけのときは通知セクションだけを出す。混在時に本文を先に置くのは、そちらが相手の
---**依頼**で、通知は「読みに行け」という副次情報だから
---@param queue Vibing.Application.MessageQueue.Item[]
---@return string
function M.build(queue)
  local notifications, messages = {}, {}
  for _, item in ipairs(queue) do
    table.insert(item.body and messages or notifications, item)
  end

  local cache = {}
  local sections = {}
  if #messages > 0 then
    table.insert(sections, message_section(messages, cache))
  end
  if #notifications > 0 then
    table.insert(sections, notification_section(notifications, cache))
  end

  return table.concat(sections, "\n\n")
end

return M
