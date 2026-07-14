---@class Vibing.PromptTemplate
---構造化タスクテンプレート（prompts/template.md）を組み立てるモジュール
local M = {}

---@param task_description string ユーザーが入力したタスクの概要
---@param context_lines string[] 自動検出済みのcontext箇条書き（例: "- リポジトリ: ..."）
---@return string|nil content
---@return string|nil error
function M.build(task_description, context_lines)
  local PromptLoader = require("vibing.core.utils.prompt_loader")
  return PromptLoader.load("template", {
    task_description = task_description,
    context_block = table.concat(context_lines, "\n"),
  })
end

return M
