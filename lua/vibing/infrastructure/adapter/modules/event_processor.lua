---@class Vibing.EventProcessor
---Processes JSON Lines events from the Agent SDK wrapper.
---Handles session, chunk, tool_use, insert_choices, error, and done events.
local M = {}

---セッションイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param session_manager Vibing.SessionManager セッション管理モジュール
---@param handle_id string ハンドルID
local function handle_session_event(msg, session_manager, handle_id)
  if msg.session_id then
    session_manager.store(handle_id, msg.session_id)
  end
end

---ツール使用イベントを処理
---@param msg table JSONデコードされたメッセージ
---@param opts Vibing.AdapterOpts アダプターオプション
local function handle_tool_use_event(msg, opts)
  if msg.tool and msg.file_path and opts.on_tool_use then
    opts.on_tool_use(msg.tool, msg.file_path)
  end
end

---選択肢挿入イベントを処理
---@param msg table JSONデコードされたメッセージ
---@param opts Vibing.AdapterOpts アダプターオプション
local function handle_insert_choices_event(msg, opts)
  if msg.questions and opts.on_insert_choices then
    opts.on_insert_choices(msg.questions)
  end
end

---チャンクイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param output string[] 出力バッファ
---@param on_chunk fun(chunk: string) チャンク受信コールバック
local function handle_chunk_event(msg, output, on_chunk)
  if msg.text then
    table.insert(output, msg.text)
    on_chunk(msg.text)
  end
end

---エラーイベントを処理
---@param msg table JSONデコードされたメッセージ
---@param error_output string[] エラー出力バッファ
local function handle_error_event(msg, error_output)
  table.insert(error_output, msg.message or "Unknown error")
end

---JSON Lines形式のイベントを処理
---@param line string JSON文字列
---@param context table 処理コンテキスト（session_manager, handle_id, opts, output, error_output, on_chunk）
---@return boolean success デコードと処理が成功した場合true
function M.process_line(line, context)
  if line == "" then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok then
    return false
  end

  -- イベントタイプに応じた処理
  if msg.type == "session" then
    handle_session_event(msg, context.session_manager, context.handle_id)
  elseif msg.type == "tool_use" then
    handle_tool_use_event(msg, context.opts)
  elseif msg.type == "insert_choices" then
    handle_insert_choices_event(msg, context.opts)
  elseif msg.type == "chunk" then
    handle_chunk_event(msg, context.output, context.on_chunk)
  elseif msg.type == "error" then
    handle_error_event(msg, context.error_output)
  end
  -- "done" type is handled by process exit

  return true
end

return M
