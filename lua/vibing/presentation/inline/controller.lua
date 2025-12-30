---@class Vibing.Presentation.InlineController
---インライン機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

---インラインアクションを実行
---@param args string アクション名または空文字列（ピッカー表示）
function M.handle_execute(args)
  if args == "" then
    -- 引数なしの場合はリッチなピッカーUIを表示
    local InlinePicker = require("vibing.ui.inline_picker")
    InlinePicker.show(function(action, instruction)
      local action_arg = action
      if instruction and instruction ~= "" then
        action_arg = action_arg .. " " .. instruction
      end
      require("vibing.application.inline.use_case").execute(action_arg)
    end)
  else
    require("vibing.application.inline.use_case").execute(args)
  end
end

return M
