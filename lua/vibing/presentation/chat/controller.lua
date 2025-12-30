---@class Vibing.Presentation.ChatController
---チャット機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

local notify = require("vibing.core.utils.notify")

---チャットウィンドウを開く（新規または既存ファイル）
---@param args string ファイルパス（空文字列の場合は新規チャット）
function M.handle_open(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  if args and args ~= "" then
    -- 既存ファイルを開く
    local session = use_case.open_file(args)
    if session then
      view.render(session)
    else
      notify.error("Failed to load: " .. args, "Chat")
    end
  else
    -- 新規チャットを開く
    local session = use_case.create_new()
    view.render(session)
  end
end

---チャットウィンドウをトグル
function M.handle_toggle()
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  if view.is_open() then
    view.close()
  else
    local session = use_case.get_or_create_session()
    view.render(session)
  end
end

---スラッシュコマンドピッカーを表示
function M.show_slash_commands()
  require("vibing.ui.command_picker").show()
end

---チャットファイルにAIタイトルを設定
function M.handle_set_file_title()
  local view = require("vibing.presentation.chat.view")

  if not view.is_current_buffer_chat() then
    notify.warn("Not in a vibing chat buffer")
    return
  end

  local handler = require("vibing.application.chat.handlers.set_file_title")
  local current_view = view.get_current()
  handler({}, current_view)
end

return M
