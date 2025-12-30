---@class Vibing.Presentation.ContextController
---コンテキスト管理のPresentation層Controller
---ユーザー入力を受け取り、Application層を呼び出す責務を持つ
local M = {}

---コンテキストにファイルまたは選択範囲を追加
---@param opts table Neovimコマンドのオプション（args, range等）
function M.handle_add(opts)
  local Context = require("vibing.application.context.manager")

  -- 優先順位1: 範囲選択（存在する場合）
  if opts.range > 0 then
    Context.add_selection()
    M._update_chat_context_if_open()
    return
  end

  -- 優先順位2: ファイルパス引数
  if opts.args ~= "" then
    Context.add(opts.args)
    M._update_chat_context_if_open()
    return
  end

  -- 優先順位3: oil.nvimバッファからファイルを追加
  local ok, oil = pcall(require, "vibing.integrations.oil")
  if ok and oil.is_oil_buffer() then
    local send_ok, err = pcall(oil.send_to_chat)
    if send_ok then
      return
    end
    -- エラーがあっても続行（通常のコンテキスト追加にフォールスルー）
  end

  -- 優先順位4: 現在のバッファ
  Context.add()
  M._update_chat_context_if_open()
end

---コンテキストをクリア
function M.handle_clear()
  local Context = require("vibing.application.context.manager")
  Context.clear()
  M._update_chat_context_if_open()
end

---@private
---チャットバッファが開いている場合、コンテキスト行を更新
function M._update_chat_context_if_open()
  local view = require("vibing.presentation.chat.view")
  if view.is_open() then
    local current_view = view.get_current()
    if current_view then
      current_view:_update_context_line()
    end
  end
end

return M
