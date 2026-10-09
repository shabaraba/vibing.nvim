---@class Vibing.Application.Chat.Search.Llm
---チャット検索が使う軽量呼び出しの一点。
---
---`title_generator` / `summarize` と同じ `lightweight = true`（ツールなし・プロジェクト設定なし・
---utility_model）で、resume も fork もしない。検索は過去のチャット「ファイル」を入力にするので、
---どのセッションの続きでもない。
local M = {}

---@param prompt string
---@param callback fun(text: string?, error: string?)
function M.request(prompt, callback)
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local collected = ""

  adapter:stream(prompt, { lightweight = true }, function(chunk)
    collected = collected .. chunk
  end, function(response)
    if response.error then
      callback(nil, response.error)
      return
    end

    local text = collected
    if text == "" and response.content then
      text = response.content
    end

    callback(vim.trim(text or ""), nil)
  end)
end

---応答テキストを行に割り、空行とツール実況行を落とす。
---軽量呼び出しではツールを無効化しているが、それが破れたときにツール行が結果に混ざらないよう、
---`title_generator` と同じ `chat_excerpt` の判定を使う。
---@param text string?
---@return string[]
function M.meaningful_lines(text)
  local chat_excerpt = require("vibing.core.utils.chat_excerpt")
  local lines = {}

  for _, line in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not chat_excerpt.is_tool_line(trimmed) then
      lines[#lines + 1] = trimmed
    end
  end

  return lines
end

---設定された言語の名前（"Japanese" 等）。未設定なら nil
---@return string?
function M.language_name()
  local language_utils = require("vibing.core.utils.language")
  local config = require("vibing").get_config()
  local code = language_utils.get_language_code(config.language, "chat")
  return code and language_utils.language_names[code]
end

return M
