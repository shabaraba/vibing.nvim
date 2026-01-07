---@class Vibing.Presentation.ChatController
---チャット機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

local notify = require("vibing.core.utils.notify")

---チャットウィンドウを開く（新規または既存ファイル）
---@param args string 引数文字列（位置指定、ファイルパス、workspace=<path>オプション）
function M.handle_open(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  -- 引数をパース（位置指定, workspace=<path>, ファイルパス）
  local position = nil
  local file_path = nil
  local workspace_root = nil

  if args and args ~= "" then
    -- スペース区切りで引数を分割
    local parts = vim.split(args, "%s+")
    for _, part in ipairs(parts) do
      -- workspace=<path> 形式をチェック
      local ws_path = part:match("^workspace=(.+)$")
      if ws_path then
        -- パスを展開（~ や . を解決）
        workspace_root = vim.fn.fnamemodify(ws_path, ":p")
        -- 末尾のスラッシュを削除
        workspace_root = workspace_root:gsub("/$", "")
      -- 位置キーワードのチェック
      elseif part == "current" or part == "right" or part == "left" then
        position = part
      else
        -- ファイルパスとして扱う
        file_path = part
      end
    end
  end

  if file_path then
    -- 既存ファイルを開く
    local session = use_case.open_file(file_path)
    if session then
      view.render(session, position, { workspace_root = workspace_root })
    else
      notify.error("Failed to load: " .. file_path, "Chat")
    end
  else
    -- 新規チャットを開く（位置指定あり/なし）
    local session = use_case.create_new({ workspace_root = workspace_root })
    view.render(session, position, { workspace_root = workspace_root })
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
