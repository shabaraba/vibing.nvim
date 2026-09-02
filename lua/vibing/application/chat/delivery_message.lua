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

  -- 文面が「止まった、読みに行け」から「報告なしで止まった」に変わったのは #643。規約では
  -- ワーカーは終わったら自分から報告し、`on_sent` の抑止マークがその直後の停止1回ぶんの
  -- watchdog を落とす。つまりここに載るのは「報告せずに止まった」チャットで、それは規約から
  -- 外れた止まり方 — 失敗・質問・承認待ちのどれか — である可能性のほうが高い
  return table.concat({
    "The following chat(s) you sent a message to have stopped without reporting back:",
    "",
    table.concat(lines, "\n"),
    "",
    "A chat that finishes its task is expected to report the result to you itself, so a stop with",
    "no report is more likely to be something else: it failed, it stopped to ask a question, or it",
    "is waiting on a tool approval. Read each one with nvim_get_buffer({ rpc_port, file_path }),",
    "look at the tail of the transcript, and decide what to do — do not treat its task as done.",
    "",
    "If other chats you dispatched are still running, do not start aggregating yet — say what you",
    "found and end the turn. You will be woken again when the next one stops.",
  }, "\n")
end

---@param items Vibing.Application.MessageQueue.Item[]
---@param cache table<number, string>
---@param sender_named boolean セクション見出しが送信元を既に名指ししているか
---@return string
local function message_section(items, cache, sender_named)
  -- 送信元が1つに定まる配達では、セクション見出し（`## Report <!-- ts from path -->`）が
  -- 既に名前を持っている。ここでも `### From` を出すと同じことを2行離れて2回言うことになる
  if sender_named and #items == 1 then
    return items[1].body
  end

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

---@class Vibing.Application.DeliveryMessage.Section
---@field kind "Request"|"Report"|"Notice" 配達セクションの種別
---@field from string? 送信元の表示パス（1つに定まらない配達では nil）

---この配達をどのセクションとして書くかを決める
---
---見出しと本文で判断が食い違わないよう、種別と送信元はここ1箇所で決めて `build` に渡す。
---
---向きは `orchestration_link.direction` に聞く（記録済みの関係から決まる）。合流した配達で
---向きが混ざる場合は `Report` に倒す: 複数のワーカーからの報告が1ターンに合流するのが
---この機構の通常の形で、依頼が同時に混ざるのは例外的だから
---@param queue Vibing.Application.MessageQueue.Item[]
---@param to_bufnr number 配達先
---@return Vibing.Application.DeliveryMessage.Section
function M.section_for(queue, to_bufnr)
  local OrchestrationLink = require("vibing.application.chat.orchestration_link")

  local senders, kind, bodies = {}, nil, 0
  for _, item in ipairs(queue) do
    if item.body then
      bodies = bodies + 1
      if item.bufnr then
        senders[item.bufnr] = true
        local direction = OrchestrationLink.direction(item.bufnr, to_bufnr)
        kind = (kind == nil or kind == direction) and direction or "Report"
      else
        -- 送信元が消えた本文（`message_queue.forget`）。匿名で配達されるので向きは決められない
        kind = kind or "Report"
      end
    end
  end

  if not kind then
    return { kind = "Notice" }
  end

  local sender_count, only_sender = 0, nil
  for bufnr in pairs(senders) do
    sender_count, only_sender = sender_count + 1, bufnr
  end

  -- 見出しが送信元を名乗れるのは、この配達が「1つのチャットからの本文1通」のときだけ。
  -- 通知が混ざっていれば通知は別のチャットについての話だし、本文が複数あれば出どころも
  -- 複数ありうる。どちらも見出しで片方だけを名指しすると、残りの出どころが消える
  if sender_count ~= 1 or bodies ~= 1 or #queue ~= 1 then
    return { kind = kind }
  end

  local name = vim.api.nvim_buf_is_valid(only_sender) and vim.api.nvim_buf_get_name(only_sender) or ""
  return {
    kind = kind,
    from = name ~= "" and require("vibing.core.utils.git").to_display_path(name) or nil,
  }
end

---溜まったものを1通にまとめる
---
---通知だけのときは通知セクションだけを出す。混在時に本文を先に置くのは、そちらが相手の
---**依頼**で、通知は「読みに行け」という副次情報だから
---@param queue Vibing.Application.MessageQueue.Item[]
---@param section Vibing.Application.DeliveryMessage.Section? `section_for` の結果
---@return string
function M.build(queue, section)
  local notifications, messages = {}, {}
  for _, item in ipairs(queue) do
    table.insert(item.body and messages or notifications, item)
  end

  local cache = {}
  local sections = {}
  if #messages > 0 then
    table.insert(sections, message_section(messages, cache, section ~= nil and section.from ~= nil))
  end
  if #notifications > 0 then
    table.insert(sections, notification_section(notifications, cache))
  end

  return table.concat(sections, "\n\n")
end

return M
