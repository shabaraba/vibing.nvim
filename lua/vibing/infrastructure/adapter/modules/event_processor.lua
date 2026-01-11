---@class Vibing.EventProcessor
---Processes JSON Lines events from the Agent SDK wrapper.
---Handles session, chunk, tool_use, insert_choices, error, and done events.
local M = {}

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

---セッションイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param sessionManager Vibing.SessionManager セッション管理モジュール
---@param handleId string ハンドルID
local function handleSessionEvent(msg, sessionManager, handleId)
  if msg.session_id then
    SessionManagerModule.store(sessionManager, handleId, msg.session_id)
  end
end

---ツール使用イベントを処理
---@param msg table JSONデコードされたメッセージ
---@param opts Vibing.AdapterOpts アダプターオプション
local function handleToolUseEvent(msg, opts)
  if msg.tool and opts.on_tool_use then
    -- file_path or command (for Bash)
    vim.schedule(function()
      opts.on_tool_use(msg.tool, msg.file_path, msg.command)
    end)
  end
end

---選択肢挿入イベントを処理
---@param msg table JSONデコードされたメッセージ
---@param opts Vibing.AdapterOpts アダプターオプション
local function handleInsertChoicesEvent(msg, opts)
  if msg.questions and opts.on_insert_choices then
    vim.schedule(function()
      opts.on_insert_choices(msg.questions)
    end)
  end
end

---パッチ保存イベントを処理
---@param msg table JSONデコードされたメッセージ
---@param opts Vibing.AdapterOpts アダプターオプション
local function handlePatchSavedEvent(msg, opts)
  if msg.filename and opts.on_patch_saved then
    vim.schedule(function()
      opts.on_patch_saved(msg.filename)
    end)
  end
end

---チャンクイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param output string[] 出力バッファ
---@param onChunk fun(chunk: string) チャンク受信コールバック
local function handleChunkEvent(msg, output, onChunk)
  if msg.text then
    table.insert(output, msg.text)
    vim.schedule(function()
      onChunk(msg.text)
    end)
  end
end

---エラーイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param errorOutput string[] エラー出力バッファ
local function handleErrorEvent(msg, errorOutput)
  table.insert(errorOutput, msg.message or "Unknown error")
end

---イベントハンドラーテーブル
---@type table<string, fun(msg: table, context: table): boolean>
local eventHandlers = {
  session = function(msg, context)
    if not context.sessionManager or not context.handleId then
      return false
    end
    handleSessionEvent(msg, context.sessionManager, context.handleId)
    return true
  end,
  tool_use = function(msg, context)
    if not context.opts then
      return false
    end
    handleToolUseEvent(msg, context.opts)
    return true
  end,
  insert_choices = function(msg, context)
    if not context.opts then
      return false
    end
    handleInsertChoicesEvent(msg, context.opts)
    return true
  end,
  patch_saved = function(msg, context)
    if not context.opts then
      return false
    end
    handlePatchSavedEvent(msg, context.opts)
    return true
  end,
  chunk = function(msg, context)
    if not context.output or not context.onChunk then
      return false
    end
    handleChunkEvent(msg, context.output, context.onChunk)
    return true
  end,
  error = function(msg, context)
    if not context.errorOutput then
      return false
    end
    handleErrorEvent(msg, context.errorOutput)
    return true
  end,
}

---JSON Lines形式のイベントを処理
---@param line string JSON文字列
---@param context table 処理コンテキスト（sessionManager, handleId, opts, output, errorOutput, onChunk）
---@return boolean success デコードと処理が成功した場合true
function M.processLine(line, context)
  if line == "" or not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok or not msg.type then
    return false
  end

  local handler = eventHandlers[msg.type]
  if handler then
    return handler(msg, context)
  end

  return true
end

return M
