---@class Vibing.Application.Chat.SubagentBroadcast
---サブエージェントを起動しうるコマンド（`/simplify`, `/code-review` 等）が同じ時間窓の内に
---複数の異なるチャットへ送られたら警告する（#700）。
---
---`/simplify` はチャット1本あたり複数のサブエージェントを起動する。これを複数チャットに
---同報すると「チャット数×サブエージェント数」の並列度になり、セッション上限に当たりやすい
---（#692の事後分析）。実際に起動されたサブエージェントの数を数えるのは別issueのスコープで、
---ここではコマンド名の一致と直近の送信先だけを見る。
local M = {}

local notify = require("vibing.core.utils.notify")
local Commands = require("vibing.application.chat.commands")

---ユーザーが`agent.orchestration.broadcast_warn_window_sec`を設定しなかったときの既定値
local DEFAULT_WINDOW_SEC = 30

---送信元bufnrとコマンド名ごとの、直近の時間窓に送った宛先の集合
---@type table<string, {targets: table<number, boolean>, last_seen: number, warned: boolean}>
local recent = {}

---@return string[]
local function configured_commands()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration
  if type(orchestration) ~= "table" then
    return {}
  end
  local list = orchestration.subagent_spawning_commands
  if type(list) ~= "table" then
    return {}
  end
  return list
end

---@return number
local function window_sec()
  local config = require("vibing.config").get()
  local orchestration = config.agent and config.agent.orchestration
  if type(orchestration) ~= "table" then
    return DEFAULT_WINDOW_SEC
  end
  local window = orchestration.broadcast_warn_window_sec
  if type(window) ~= "number" or window < 0 then
    return DEFAULT_WINDOW_SEC
  end
  return window
end

---@param command_name string
---@return boolean
local function is_subagent_spawning(command_name)
  for _, name in ipairs(configured_commands()) do
    if name == command_name then
      return true
    end
  end
  return false
end

---`nvim_chat_send_message`が呼ばれるたびに呼ぶ。サブエージェントを起動しうるコマンドが
---短時間に複数の異なる宛先へ送られたら、その1回だけ警告する。
---
---宛先が実際に送信・キュー・拒否のどれになったかには関わらない — 同報の意図は呼び出しの
---時点で決まっているため、結果を待たずに判定してよい
---@param from_bufnr number? 送信元（省略時はコマンド名だけで束ねる）
---@param to_bufnr number 宛先
---@param message string
function M.check(from_bufnr, to_bufnr, message)
  if type(message) ~= "string" then
    return
  end

  local command_name = Commands.parse(message)
  if not command_name or not is_subagent_spawning(command_name) then
    return
  end

  local window = window_sec()
  if window <= 0 then
    return
  end

  local key = string.format("%s:%s", tostring(from_bufnr or "?"), command_name)
  local now = os.time()
  local entry = recent[key]
  if entry and now - entry.last_seen > window then
    entry = nil
  end
  if not entry then
    entry = { targets = {}, last_seen = now, warned = false }
    recent[key] = entry
  end
  entry.last_seen = now

  if entry.targets[to_bufnr] then
    return
  end
  entry.targets[to_bufnr] = true

  local target_count = 0
  for _ in pairs(entry.targets) do
    target_count = target_count + 1
  end

  -- 2件目の異なる宛先が出た瞬間に1回だけ警告する。3件目以降まで同じ文言を出し続けても
  -- 得る情報が増えないので、同じ時間窓では黙る
  if target_count > 1 and not entry.warned then
    entry.warned = true
    notify.warn(
      string.format(
        "/%s was just sent to %d different chats within %ds. This command spawns its own "
          .. "subagents per chat, so broadcasting it multiplies concurrency by that many chats. "
          .. "Parallelization inside work that already has its own chat belongs to subagents, "
          .. "not more chats (#692) — send it to one chat and let it fan out internally.",
        command_name,
        target_count,
        window
      ),
      "Orchestration"
    )
  end
end

---テスト用。in-memory状態を空にする
function M.reset()
  recent = {}
end

return M
