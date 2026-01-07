---@class Vibing.ActionConfig
---@field prompt string アクションの基本プロンプト
---@field tools string[] 許可するツールリスト（Edit, Write等）
---@field use_output_buffer boolean 結果をフローティングウィンドウで表示するか

---@class Vibing.ActionConfigModule
local M = {}

---事前定義されたインラインアクション設定
---fix, feat, explain, refactor, testの5種類を提供
---@type table<string, Vibing.ActionConfig>
M.actions = {
  fix = {
    prompt = "Fix the following code issues:",
    tools = { "Edit" },
    use_output_buffer = false,
  },
  feat = {
    prompt = "Make the requested changes to the selected code by writing actual code. You MUST use Edit or Write tools to modify or create files. Do not just explain or provide suggestions - write the implementation directly into the files:",
    tools = { "Edit", "Write" },
    use_output_buffer = false,
  },
  explain = {
    prompt = "Explain the following code:",
    tools = {},
    use_output_buffer = true,
  },
  refactor = {
    prompt = "Refactor the following code for better readability and maintainability:",
    tools = { "Edit" },
    use_output_buffer = false,
  },
  test = {
    prompt = "Generate tests for the following code:",
    tools = { "Edit", "Write" },
    use_output_buffer = false,
  },
}

---アクション設定を取得
---@param action_name string アクション名
---@return Vibing.ActionConfig|nil
function M.get(action_name)
  return M.actions[action_name]
end

---事前定義アクションかどうかを判定
---@param action_name string アクション名
---@return boolean
function M.is_predefined(action_name)
  return M.actions[action_name] ~= nil
end

return M
