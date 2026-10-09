---@class Vibing.Application.Chat.Search.SessionAnswer
---`:VibingSessionSearch` のエージェントの答え（末尾の JSON）を、セッションの一覧に読み替える。
local M = {}

local BackgroundAgent = require("vibing.application.chat.search.background_agent")

---`nvim_session_search` が扱う CLI。これ以外の値は、モデルが書き間違えたものとして捨てる
local BACKENDS = { claude = true, codex = true }

---@class Vibing.Session.Search.Result
---@field backend "claude"|"codex"
---@field session_id string
---@field cwd string? セッションを始めたディレクトリ。ログに無ければ nil
---@field updated_at string
---@field title string
---@field summary string
---@field group string

local one_line = BackgroundAgent.one_line

---@param session table
---@param label string
---@return Vibing.Session.Search.Result?
local function to_result(session, label)
  if type(session) ~= "table" or not BACKENDS[session.backend] then
    return nil
  end
  local session_id = one_line(session.session_id)
  if session_id == "" then
    return nil
  end
  local cwd = one_line(session.cwd)
  return {
    backend = session.backend,
    session_id = session_id,
    cwd = cwd ~= "" and cwd or nil,
    updated_at = one_line(session.updated_at),
    title = one_line(session.title),
    summary = one_line(session.summary),
    group = label,
  }
end

---@param text string?
---@return Vibing.Session.Search.Result[]? results
---@return string? error
function M.parse(text)
  local decoded, err = BackgroundAgent.last_json(text)
  if not decoded then
    return nil, err
  end
  if type(decoded.groups) ~= "table" then
    return nil, "the search agent returned a malformed result"
  end

  local results = {}
  local seen = {}

  for _, group in ipairs(decoded.groups) do
    local label = type(group) == "table" and one_line(group.label) or ""
    local sessions = type(group) == "table" and type(group.sessions) == "table" and group.sessions or {}

    for _, session in ipairs(sessions) do
      local result = to_result(session, label)
      local key = result and (result.backend .. ":" .. result.session_id)
      if result and not seen[key] then
        seen[key] = true
        results[#results + 1] = result
      end
    end
  end

  return results, nil
end

---`2026-10-09T05:12:33.000Z` をローカル時刻の `2026-10-09 14:12` に詰める。
---読めない形はそのまま返す
---@param updated_at string
---@return string
function M.short_date(updated_at)
  local y, mo, d, h, mi, s, zone = updated_at:match("^(%d+)%-(%d+)%-(%d+)[T ](%d+):(%d+):(%d+)[%.%d]*(Z?)")
  if not y then
    return updated_at
  end
  local stamp = os.time({
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
  })
  if zone == "Z" then
    local now = os.time()
    stamp = stamp + os.difftime(now, os.time(os.date("!*t", now) --[[@as osdateparam]]))
  end
  return os.date("%Y-%m-%d %H:%M", stamp) --[[@as string]]
end

return M
