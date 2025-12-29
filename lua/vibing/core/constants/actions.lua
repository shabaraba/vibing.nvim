---@class Vibing.Core.ActionsConstants
---インラインアクションの定数定義
local M = {}

---@class Vibing.ActionDefinition
---@field name string アクション名
---@field prompt string プロンプトテンプレート
---@field tools string[] 使用するツール
---@field use_output_buffer boolean 出力バッファを使用するか

---インラインアクションの定義
---@type table<string, Vibing.ActionDefinition>
M.INLINE_ACTIONS = {
  fix = {
    name = "fix",
    prompt = "Fix any issues in the following code:",
    tools = { "Read", "Edit", "Write", "Glob", "Grep" },
    use_output_buffer = false,
  },
  feat = {
    name = "feat",
    prompt = "Implement the following feature based on the code:",
    tools = { "Read", "Edit", "Write", "Glob", "Grep" },
    use_output_buffer = false,
  },
  explain = {
    name = "explain",
    prompt = "Explain the following code in detail:",
    tools = { "Read", "Glob", "Grep" },
    use_output_buffer = true,
  },
  refactor = {
    name = "refactor",
    prompt = "Refactor the following code to improve quality:",
    tools = { "Read", "Edit", "Write", "Glob", "Grep" },
    use_output_buffer = false,
  },
  test = {
    name = "test",
    prompt = "Generate tests for the following code:",
    tools = { "Read", "Edit", "Write", "Glob", "Grep" },
    use_output_buffer = false,
  },
}

---アクション名のリスト
---@type string[]
M.ACTION_NAMES = vim.tbl_keys(M.INLINE_ACTIONS)

return M
