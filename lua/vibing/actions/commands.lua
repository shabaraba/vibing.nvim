---@class Vibing.Commands
local M = {}

---チャットを開く
function M.chat()
  require("vibing.actions.chat").open()
end

---チャットを閉じる
function M.chat_close()
  require("vibing.actions.chat").close()
end

---チャットをトグル
function M.chat_toggle()
  require("vibing.actions.chat").toggle()
end

---fix アクション
function M.fix()
  require("vibing.actions.inline").execute("fix")
end

---feat アクション
function M.feat()
  require("vibing.actions.inline").execute("feat")
end

---explain アクション
function M.explain()
  require("vibing.actions.inline").execute("explain")
end

---refactor アクション
function M.refactor()
  require("vibing.actions.inline").execute("refactor")
end

---test アクション
function M.test()
  require("vibing.actions.inline").execute("test")
end

---カスタムプロンプト（出力バッファ）
---@param prompt string
function M.ask(prompt)
  require("vibing.actions.inline").custom(prompt, true)
end

---カスタムプロンプト（直接実行）
---@param prompt string
function M.do_action(prompt)
  require("vibing.actions.inline").custom(prompt, false)
end

---コンテキスト追加
---@param path? string
function M.add_context(path)
  require("vibing.context").add(path)
end

---コンテキストクリア
function M.clear_context()
  require("vibing.context").clear()
end

---実行をキャンセル
function M.cancel()
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  if adapter then
    local cancelled = adapter:cancel()
    if cancelled then
      notify.info("Cancelled")
    end
  end
end

return M
