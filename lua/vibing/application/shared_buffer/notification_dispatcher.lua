---Notification dispatcher for multi-agent coordination
---Manages session registration and dispatches notifications to relevant Claude sessions
local M = {}

---@class RegisteredSession
---@field session_id string
---@field bufnr number
---@field on_notification function

---@type table<string, RegisteredSession>
local registered_sessions = {}

---Claude セッションを登録
---@param claude_id string
---@param session_id string
---@param bufnr number
---@param on_notification function
function M.register_session(claude_id, session_id, bufnr, on_notification)
  registered_sessions[claude_id] = {
    session_id = session_id,
    bufnr = bufnr,
    on_notification = on_notification,
  }
end

---セッションの登録を解除
---@param claude_id string
function M.unregister_session(claude_id)
  registered_sessions[claude_id] = nil
end

---全てのセッションの登録を解除
function M.unregister_all()
  registered_sessions = {}
end

---通知を配送
---@param message SharedMessage
function M.dispatch(message)
  local MessageParser = require("vibing.application.shared_buffer.message_parser")

  -- @All の場合は全セッションに通知
  if vim.tbl_contains(message.mentions, "All") then
    for claude_id, session in pairs(registered_sessions) do
      -- 自分自身には通知しない
      if claude_id ~= message.from_claude_id then
        local ok, err = pcall(session.on_notification, message)
        if not ok then
          vim.notify(
            string.format("[vibing] Notification error for %s: %s", claude_id, err),
            vim.log.levels.ERROR
          )
        end
      end
    end
    return
  end

  -- 特定の Claude へのメンションを処理
  for _, mention in ipairs(message.mentions) do
    local session = registered_sessions[mention]
    if session then
      local ok, err = pcall(session.on_notification, message)
      if not ok then
        vim.notify(
          string.format("[vibing] Notification error for %s: %s", mention, err),
          vim.log.levels.ERROR
        )
      end
    end
  end
end

---登録されているセッション一覧を取得
---@return table<string, RegisteredSession>
function M.get_registered_sessions()
  return vim.deepcopy(registered_sessions)
end

---特定の Claude ID が登録されているか確認
---@param claude_id string
---@return boolean
function M.is_registered(claude_id)
  return registered_sessions[claude_id] ~= nil
end

---セッション数を取得
---@return number
function M.get_session_count()
  local count = 0
  for _ in pairs(registered_sessions) do
    count = count + 1
  end
  return count
end

return M
