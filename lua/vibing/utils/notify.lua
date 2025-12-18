---@class Vibing.Notify
---vibing.nvimのエラーメッセージングユーティリティ
---全モジュールで統一されたフォーマットのエラーメッセージを提供
---vim.notifyのラッパーとして動作し、プレフィックスとフォーマットを自動管理
local M = {}

---ログレベル定数
---vim.log.levelsのエイリアス（可読性向上のため）
M.levels = vim.log.levels

---通知メッセージを送信（統一フォーマット）
---全てのメッセージに`[vibing]`プレフィックスを付与
---コンテキスト（action名）を指定可能
---@param message string メッセージ本文
---@param level number ログレベル（vim.log.levels.ERROR等）
---@param action string? アクション名（省略可、指定時は"action: message"形式）
function M.notify(message, level, action)
  local formatted_message
  if action then
    formatted_message = string.format("[vibing] %s: %s", action, message)
  else
    formatted_message = string.format("[vibing] %s", message)
  end
  vim.notify(formatted_message, level)
end

---エラーメッセージを送信（ERROR レベル）
---操作が完全に失敗し、ユーザー介入が必要な場合に使用
---@param message string エラーメッセージ
---@param action string? アクション名（省略可）
function M.error(message, action)
  M.notify(message, M.levels.ERROR, action)
end

---警告メッセージを送信（WARN レベル）
---操作は継続するが、期待と異なる結果の場合に使用
---@param message string 警告メッセージ
---@param action string? アクション名（省略可）
function M.warn(message, action)
  M.notify(message, M.levels.WARN, action)
end

---情報メッセージを送信（INFO レベル）
---正常な操作の完了通知に使用
---@param message string 情報メッセージ
---@param action string? アクション名（省略可）
function M.info(message, action)
  M.notify(message, M.levels.INFO, action)
end

---デバッグメッセージを送信（DEBUG レベル）
---開発者向けの詳細情報に使用
---@param message string デバッグメッセージ
---@param action string? アクション名（省略可）
function M.debug(message, action)
  M.notify(message, M.levels.DEBUG, action)
end

return M
