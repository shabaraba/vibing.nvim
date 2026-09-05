---@class Vibing.Application.DeliveryMessage
---`message_queue` が溜めたものを、受け取るチャットに読ませる1通のテキストにする。
---
---キューの状態機械とは別モジュールにしてある。ここが持つのは「配られたものをどう見せるか」
---— セクションの種別・送信元の名指し・モデルに読ませる散文 — であって、待ち合わせの規則
---ではない。文面の推敲で配達の順序が変わることはないし、その逆もない。
---
---見出しと本文の判断が食い違わないよう、`deliver` が `section_for` → `build` → 送信の順序を
---所有する。この3つを呼び出し側で並べていたころ、片方の経路だけが送信元を名乗るという
---食い違いが実際に起きた。
local M = {}

---@param bufnr number
---@param cache table<number, string>
---@return string
---バッファの表示パス。名前を持たないバッファでは nil
---
---`to_display_path` は解決を `git rev-parse` に投げ、それはキャッシュを持たない同期の
---プロセス起動。1通に同じチャットが複数回現れるのは普通（同じ相手からの複数の報告）なので、
---1通を組み立てる間だけ覚える。バッファ名は改名されうるので、それ以上は持ち越さない
---@param bufnr number
---@param cache table<number, string>
---@return string?
local function resolve_path(bufnr, cache)
  local cached = cache[bufnr]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  -- frontmatter の `orchestrated` と同じ表示形式にする。モデルが読みに行く先を、
  -- 記録と別の形で名指ししない
  local path = name ~= "" and require("vibing.core.utils.git").to_display_path(name) or nil

  cache[bufnr] = path or false
  return path
end

---@param bufnr number
---@param cache table<number, string>
---@return string
local function display_path(bufnr, cache)
  return resolve_path(bufnr, cache) or "unnamed"
end

---@param items Vibing.Application.MessageQueue.Item[]
---@param cache table<number, string>
---@return string
local function notification_section(items, cache)
  -- パスを先に置くのはシステムプロンプトの orchestrator 行と同じ理由で、再起動を跨いで
  -- 意味を保つのはパスのほうだから（#641）
  local lines = {}
  local any_blocked = false
  for _, item in ipairs(items) do
    local path = display_path(item.bufnr, cache)
    if item.reason then
      any_blocked = true
      -- 状態を名指しするのは、読み手が「答えれば動く」のか「ユーザーにしか外せない」のかを
      -- `nvim_get_buffer` の1往復なしで分けられるようにするため。語彙は `chat_status` と同じ
      table.insert(lines, string.format("- %s (chat buffer %d) — status: %s", path, item.bufnr, item.reason))
    else
      table.insert(lines, string.format("- %s (chat buffer %d)", path, item.bufnr))
    end

    -- 最終セクションの末尾を添えるのが #693 の主題そのもの。ここが空なら
    -- `nvim_get_buffer` を1往復するしかなかった
    if item.tail then
      table.insert(lines, "  last lines:")
      table.insert(lines, "  ```")
      for _, tail_line in ipairs(vim.split(item.tail, "\n", { plain = true })) do
        table.insert(lines, "  " .. tail_line)
      end
      table.insert(lines, "  ```")
    end
  end

  -- 文面が「止まった、読みに行け」から「報告なしで止まった」に変わったのは #643。規約では
  -- ワーカーは終わったら自分から報告し、`on_sent` の抑止マークがその直後の停止1回ぶんの
  -- watchdog を落とす。つまりここに載るのは「報告せずに止まった」チャットで、それは規約から
  -- 外れた止まり方 — 失敗・質問・承認待ちのどれか — である可能性のほうが高い。
  --
  -- 状態が判っている分はそう言い切る。そちらは推測ではなく、そのチャットが自力では
  -- 抜けられないことが確定しているので、文面も「読みに行け」ではなく「動かしに行け」になる
  local lead = any_blocked
      and "The following chat(s) you sent a message to have stopped and cannot continue on their own:"
    or "The following chat(s) you sent a message to have stopped without reporting back:"

  -- `waiting_approval` の行だけ設定で変わる。既定では外せるのはユーザーだけなので
  -- 「誰が何で止まっているか言え」で終わりだが、`delegated_approval` が有効なら
  -- 読み手自身が答えられる。無効なまま「答えろ」と書くと、モデルは必ず失敗する呼び出しを
  -- 1回してからユーザーに回すことになる（`approval_delegate.answer` が断る）
  local waiting_approval_lines = require("vibing.application.chat.approval_delegate").enabled()
      and {
        "- waiting_approval — it is sitting on a tool-approval prompt. Read what it is stuck on",
        "  with nvim_get_buffer, then answer it with nvim_chat_answer_approval({ rpc_port,",
        "  file_path, action, from_bufnr }) if the tool is plainly within the task you briefed it",
        "  with. If it is not, say which chat is blocked and on what, and let the user decide.",
      }
    or {
      "- waiting_approval — it is sitting on a tool-approval prompt. Only the user can clear that",
      "  one, so say which chat is blocked and on what.",
    }

  local blocked_explanation = {
    "A chat with a status above will not move again until someone acts on it:",
    "",
    "- asked_question — it is waiting for an answer. Read the question with",
    "  nvim_get_buffer({ rpc_port, file_path }) and answer it with nvim_chat_send_message",
    "  (passing from_bufnr), or put it to the user if only they can decide.",
  }
  vim.list_extend(blocked_explanation, waiting_approval_lines)
  vim.list_extend(blocked_explanation, {
    "- error — its last turn failed. Read the tail of the transcript and decide whether to",
    "  re-brief it or report the failure.",
    "",
    "A chat listed without a status stopped without reporting back; read it the same way and do",
    "not treat its task as done.",
  })

  local explanation = any_blocked and blocked_explanation
    or {
      "A chat that finishes its task is expected to report the result to you itself, so a stop with",
      "no report is more likely to be something else: it failed, it stopped to ask a question, or it",
      "is waiting on a tool approval. Read each one with nvim_get_buffer({ rpc_port, file_path }),",
      "look at the tail of the transcript, and decide what to do — do not treat its task as done.",
    }

  return table.concat({
    lead,
    "",
    table.concat(lines, "\n"),
    "",
    table.concat(explanation, "\n"),
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
  -- 「応答中に届いた」とは言わない。この経路は即配達でも通る（送信元のバッファに名前が
  -- なければ見出しが名乗れず、ここに落ちる）ので、キューに積まれた前提の文面は嘘になる
  return table.concat({
    #blocks == 1 and "Another chat sent you this:"
      or string.format("%d messages arrived from other chats:", #blocks),
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
function M.section_for(queue, to_bufnr, cache)
  local OrchestrationLink = require("vibing.application.chat.orchestration_link")

  local kind = nil
  for _, item in ipairs(queue) do
    if item.body then
      -- 送信元が消えた本文（`message_queue.forget`）は匿名で配達されるので向きを決められない
      local direction = item.bufnr and OrchestrationLink.direction(item.bufnr, to_bufnr) or "Report"
      kind = (kind == nil or kind == direction) and direction or "Report"
    end
  end

  if not kind then
    return { kind = "Notice" }
  end

  -- 見出しが送信元を名乗れるのは、この配達が「1つのチャットからの本文1通」のときだけ。
  -- 通知が混ざっていれば通知は別のチャットについての話だし、本文が複数あれば出どころも
  -- 複数ありうる。どちらも見出しで片方だけを名指しすると、残りの出どころが消える。
  -- キューが1件で `kind` が決まっているなら、その1件は必ず本文なので添字で取れる
  if #queue ~= 1 or not queue[1].bufnr then
    return { kind = kind }
  end

  return { kind = kind, from = resolve_path(queue[1].bufnr, cache or {}) }
end

---溜まったものを1通にまとめる
---
---通知だけのときは通知セクションだけを出す。混在時に本文を先に置くのは、そちらが相手の
---**依頼**で、通知は「読みに行け」という副次情報だから
---@param queue Vibing.Application.MessageQueue.Item[]
---@param section Vibing.Application.DeliveryMessage.Section? `section_for` の結果
---@param cache table<number, string>? 表示パスの使い回し（`section_for` と共有する）
---@return string
function M.build(queue, section, cache)
  local notifications, messages = {}, {}
  for _, item in ipairs(queue) do
    table.insert(item.body and messages or notifications, item)
  end

  cache = cache or {}
  local sections = {}
  if #messages > 0 then
    table.insert(sections, message_section(messages, cache, section ~= nil and section.from ~= nil))
  end
  if #notifications > 0 then
    table.insert(sections, notification_section(notifications, cache))
  end

  return table.concat(sections, "\n\n")
end

---1通にまとめて、宛先のチャットに新しいターンとして配達する
---
---`section_for` → `build` → 送信の順序をここが所有する。呼び出し側に並べさせていたころ、
---即配達経路が `section` を渡さずに送っていたせいで、同じ報告が相手の状態によって別の形に
---見えていた。3手のうち1つを渡し忘れても文法上は成立してしまうので、手順ごと1箇所に置く
---@param queue Vibing.Application.MessageQueue.Item[]
---@param to_bufnr number
---@param sender string?
---@return {success: boolean, bufnr: number}
function M.deliver(queue, to_bufnr, sender)
  local cache = {}
  local section = M.section_for(queue, to_bufnr, cache)
  local text = M.build(queue, section, cache)
  return require("vibing.presentation.chat.modules.programmatic_sender").send(to_bufnr, text, sender, section)
end

return M
