---@class Vibing.ContextFormatter
local M = {}

---プロンプトとコンテキストを統合
---コンテキストが空の場合は元のプロンプトをそのまま返す
---@param prompt string ユーザーのプロンプト
---@param contexts string[] @file:形式のコンテキストリスト（例: "@file:path.lua"）
---@param position "prepend"|"append" コンテキストの配置位置（デフォルト: "prepend"）
---@return string formatted_prompt 統合されたプロンプト（コンテキスト + プロンプト）
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
---"# Context Files" ヘッダーに続いて各コンテキストを改行区切りで出力
---コンテキストが空の場合は空文字列を返す
---@param contexts string[] @file:形式のコンテキストリスト（例: "@file:path.lua"）
---@return string formatted_section フォーマットされたコンテキストセクション（Markdown形式）
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
---コンテキストをカンマ区切りで連結して返す
---コンテキストが空の場合は "No context" を返す
---@param contexts string[] @file:形式のコンテキストリスト（例: "@file:path.lua"）
---@return string display_string カンマ区切りの表示用文字列、または "No context"
function M.format_for_display(contexts)
  if not contexts or #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

return M
