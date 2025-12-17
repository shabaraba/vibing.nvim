---@class Vibing.ContextFormatter
local M = {}

---プロンプトとコンテキストを統合
---@param prompt string ユーザーのプロンプト
---@param contexts string[] @file:形式のコンテキストリスト
---@param position "prepend"|"append" コンテキストの配置位置
---@return string formatted_prompt 統合されたプロンプト
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
---@param contexts string[] @file:形式のコンテキストリスト
---@return string formatted_section フォーマットされたコンテキストセクション
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
---@param contexts string[] @file:形式のコンテキストリスト
---@return string display_string 表示用文字列
function M.format_for_display(contexts)
  if not contexts or #contexts == 0 then
    return "No context"
  end
  return table.concat(contexts, ", ")
end

return M
