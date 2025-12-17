---@class Vibing.ContextFormatter
---コンテキストフォーマットモジュール
---プロンプトとコンテキストの統合、セクション生成、表示用フォーマットを提供
local M = {}

---プロンプトとコンテキストを統合
---ユーザーのプロンプトにコンテキストファイルリストを統合してClaudeに送信する最終プロンプトを生成
---positionで先頭（prepend）または末尾（append）に配置を切り替え可能
---コンテキストなしの場合はプロンプトをそのまま返す
---@param prompt string ユーザーのプロンプト（メッセージ本文）
---@param contexts string[] @file:path形式のコンテキスト配列（例: {"@file:init.lua", "@file:config.lua"}）
---@param position "prepend"|"append" コンテキストの配置位置（"prepend": プロンプト前、"append": プロンプト後、デフォルトはprepend）
---@return string formatted_prompt 統合されたプロンプト（コンテキストセクション + プロンプトまたはプロンプト + コンテキストセクション）
function M.format_prompt(prompt, contexts, position)
  if not contexts or #contexts == 0 then
    return prompt
  end

  local context_section = M.format_contexts_section(contexts)

  if position == "append" then
    return prompt .. "\n\n" .. context_section
  else
    -- デフォルトは先頭（prepend）
    return context_section .. "\n\n" .. prompt
  end
end

---コンテキストセクションをフォーマット
---"# Context Files"ヘッダーとコンテキストリストを結合して改行区切りのセクションを生成
---format_prompt()から呼び出され、最終プロンプトに統合される
---コンテキストなしの場合は空文字列を返す
---@param contexts string[] @file:path形式のコンテキスト配列
---@return string formatted_section フォーマットされたコンテキストセクション（"# Context Files\n@file:init.lua\n@file:config.lua"形式）
function M.format_contexts_section(contexts)
  if not contexts or #contexts == 0 then
    return ""
  end

  local lines = { "# Context Files" }
  for _, ctx in ipairs(contexts) do
    table.insert(lines, ctx)
  end
  return table.concat(lines, "\n")
end

---コンテキストを表示用にフォーマット
---チャットバッファのコンテキスト表示行やステータス表示で使用
---カンマ区切りの一覧を返す（例: "@file:init.lua, @file:config.lua"）
---コンテキストなしの場合は"No context"を返す
---@param contexts string[] @file:path形式のコンテキスト配列
---@return string display_string 表示用文字列（カンマ区切り一覧または"No context"）
function M.format_for_display(contexts)
  if not contexts or #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

return M
