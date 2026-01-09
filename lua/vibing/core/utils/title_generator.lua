---Title generation utilities
---@class Vibing.Utils.TitleGenerator
---会話内容からAIを使用してタイトルを生成するユーティリティ
---:VibingSetFileTitleコマンドで使用
local M = {}

local filename_util = require("vibing.core.utils.filename")

---会話履歴からAIにタイトルを生成させる
---Ollamaが有効な場合はOllama、それ以外はClaudeを使用してタイトルを生成
---結果はコールバックで非同期に返される
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
function M.generate_from_conversation(conversation, callback)
  if not conversation or #conversation == 0 then
    callback(nil, "No conversation to generate title from")
    return
  end

  local vibing = require("vibing")

  -- タイトル生成専用のアダプターを取得
  local adapter = vibing.get_adapter_for("title")

  -- 長い会話の場合は最初の2メッセージと最後の2メッセージのみを使用
  local max_messages = 4
  local selected_conversation = {}

  if #conversation <= max_messages then
    selected_conversation = conversation
  else
    -- 最初の2メッセージ
    table.insert(selected_conversation, conversation[1])
    table.insert(selected_conversation, conversation[2])
    -- 最後の2メッセージ
    table.insert(selected_conversation, conversation[#conversation - 1])
    table.insert(selected_conversation, conversation[#conversation])
  end

  local conversation_text = {}
  for _, msg in ipairs(selected_conversation) do
    -- 各メッセージを300文字に制限
    local content = msg.content
    if #content > 300 then
      content = content:sub(1, 300) .. "..."
    end
    table.insert(conversation_text, string.format("[%s]: %s", msg.role, content))
  end

  local prompt = table.concat(conversation_text, "\n\n")
    .. "\n\n"
    .. "Based on the above conversation, generate a descriptive title (20-50 characters) that captures the main topic. "
    .. "The title should be suitable for a filename - use only English alphanumeric characters, spaces, and hyphens. "
    .. "Focus on the technical topic discussed (e.g., 'Ollama Streaming Fix', 'Buffer Error Resolution', 'API Integration'). "
    .. "Do NOT include: dates, timestamps, prefixes like 'chat', file extensions, or underscores. "
    .. "Respond with ONLY the title, nothing else. Do not use Chinese characters."

  local collected_response = ""

  -- Ollamaの場合は言語設定を追加
  local opts = {}
  if adapter.name == "ollama" then
    opts.language = "en" -- タイトルは英数字のみなので英語で統一
  end

  adapter:stream(prompt, opts, function(chunk)
    collected_response = collected_response .. chunk
  end, function(response)
    if response.error then
      callback(nil, response.error)
      return
    end

    local title = collected_response
    if title == "" and response.content then
      title = response.content
    end

    title = vim.trim(title)
    title = filename_util.sanitize(title)

    if title == "" then
      callback(nil, "Failed to generate valid title")
      return
    end

    callback(title, nil)
  end)
end

return M
