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
  if msg.tool and msg.file_path and opts.on_tool_use then
    vim.schedule(function()
      opts.on_tool_use(msg.tool, msg.file_path)
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

---JSON Lines形式のイベントを処理
---@param line string JSON文字列
---@param context table 処理コンテキスト（sessionManager, handleId, opts, output, errorOutput, onChunk）
---@return boolean success デコードと処理が成功した場合true
function M.processLine(line, context)
  if line == "" then
    return false
  end

  -- Validate required context fields
  if not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    return false
  end

  -- Validate msg.type exists
  if not msg.type then
    return false
  end

  -- イベントタイプに応じた処理
  if msg.type == "session" then
    if not context.sessionManager or not context.handleId then
      return false
    end
    handleSessionEvent(msg, context.sessionManager, context.handleId)
  elseif msg.type == "tool_use" then
    if not context.opts then
      return false
    end
    handleToolUseEvent(msg, context.opts)
  elseif msg.type == "insert_choices" then
    if not context.opts then
      return false
    end
    handleInsertChoicesEvent(msg, context.opts)
  elseif msg.type == "chunk" then
    if not context.output or not context.onChunk then
      return false
    end
    handleChunkEvent(msg, context.output, context.onChunk)
  elseif msg.type == "error" then
    if not context.errorOutput then
      return false
    end
    handleErrorEvent(msg, context.errorOutput)
  end
  -- "done" type is handled by process exit

  return true
end

return M
