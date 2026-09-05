---@class Vibing.Application.Chat.Concurrency
---同時に走らせるチャットの本数に上限を設ける。
---
---扇状に配ったワーカーは全員が同時に走る。数が増えれば増えるほど1本あたりのレート制限への
---当たりが早くなり、ローカルでは CLI プロセスがそのぶん並ぶ。上限はそれを「後で配る」に
---変えるだけで、捨てはしない — 配達待ちは `message_queue` に残り、枠が空いた完了イベントで
---配り直される。
---
---**人間の `<CR>` は決して止めない。** 見るのは機械が始める送信（`nvim_chat_send_message` と
---キューの配達）だけで、`ChatBuffer:send_message()` 本体には手を入れていない。ユーザーが
---打った送信が「上限です」で黙って止まるのは、この機能が買う価値のあるものではない。
local M = {}

---0（および未設定）は無制限。既定で無効なのは、有効にすると既存のオーケストレーションの
---配達順が黙って変わるため。この機能は「レート制限に当たるようになったら締める」ための
---つまみで、締めていないことが問題になる環境ばかりではない
local UNLIMITED = 0

---@return number limit 0なら無制限
function M.limit()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration

  -- 型を見るのは `orchestration = true` のような壊れた設定で `setup()` 後の送信ごとに
  -- 落ちないため。`chat_notifications` を読む側と同じ配慮
  if type(orchestration) ~= "table" then
    return UNLIMITED
  end

  local limit = orchestration.max_concurrent
  if type(limit) ~= "number" or limit < 0 then
    return UNLIMITED
  end
  return limit
end

---@return number limit 0なら無制限
function M.subagent_limit()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration

  if type(orchestration) ~= "table" then
    return UNLIMITED
  end

  local limit = orchestration.max_concurrent_subagents
  if type(limit) ~= "number" or limit < 0 then
    return UNLIMITED
  end
  return limit
end

---いま応答中のチャットの本数
---@return number
function M.responding_count()
  local count = 0
  for _, chat_buf in pairs(require("vibing.presentation.chat.view").list_chat_buffers()) do
    if chat_buf:is_responding() then
      count = count + 1
    end
  end
  return count
end

---いま起動中の（Task/Agentツールの結果がまだ返っていない）サブエージェントの合計本数。
---チャット本数だけを見ると、5チャットが上限内でも各自が4つ起動すれば実際は20並列になる（#701）
---@return number
function M.subagent_count()
  return require("vibing.infrastructure.adapter.modules.active_stream_registry").total_subagent_count()
end

---新しいターンを1本増やせない状態か
---
---チャット本数だけでなく、既存チャットが内部で起動しているサブエージェントも合計に含める。
---`max_concurrent_subagents` はそれとは別に、サブエージェントの本数だけを単独で締めるつまみ
---@return boolean
function M.at_capacity()
  local limit = M.limit()
  local sub_limit = M.subagent_limit()
  if limit <= UNLIMITED and sub_limit <= UNLIMITED then
    return false
  end

  local subagents = M.subagent_count()
  if sub_limit > UNLIMITED and subagents >= sub_limit then
    return true
  end
  if limit > UNLIMITED and (M.responding_count() + subagents) >= limit then
    return true
  end
  return false
end

---上限に当たったことを送信元に返す文言
---
---「いま混んでいる」と「待てば通る」の両方を書く。前者だけだと、モデルは同じ送信をそのまま
---再試行して同じ理由で断られ続ける
---@return string
function M.at_capacity_message()
  return string.format(
    "%d chats and %d of their subagents are already in flight, at or above the configured limit "
      .. "(agent.orchestration.max_concurrent = %d, max_concurrent_subagents = %d). Pass "
      .. "queue_if_busy so the message is delivered when one of them finishes.",
    M.responding_count(),
    M.subagent_count(),
    M.limit(),
    M.subagent_limit()
  )
end

return M
