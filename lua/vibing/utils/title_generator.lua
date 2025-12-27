---Title generation utilities
---@class Vibing.Utils.TitleGenerator
---会話内容からAIを使用してタイトルを生成するユーティリティ
---:VibingSetFileTitleコマンドで使用
local M = {}

local filename_util = require("vibing.utils.filename")

---会話履歴からAIにタイトルを生成させる
---Claudeに会話全体を送信し、簡潔なファイル名用タイトルを生成
---結果はコールバックで非同期に返される
---@param conversation {role: string, content: string}[] 会話履歴
---@param callback fun(title: string?, error: string?) 結果コールバック
function M.generate_from_conversation(conversation, callback)
  if not conversation or #conversation == 0 then
    callback(nil, "No conversation to generate title from")
    return
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local conversation_text = {}
  for _, msg in ipairs(conversation) do
    table.insert(conversation_text, string.format("[%s]: %s", msg.role, msg.content))
  end

  local prompt = table.concat(conversation_text, "\n\n")
    .. "\n\n"
    .. "Based on the above conversation, generate a concise title (maximum 30 characters) that summarizes the main topic. "
    .. "The title should be suitable for a filename - use only alphanumeric characters, spaces, and hyphens. "
    .. "Respond with ONLY the title, nothing else."

  local collected_response = ""

  adapter:stream(prompt, {}, function(chunk)
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
