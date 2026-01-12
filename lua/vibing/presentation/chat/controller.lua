---@class Vibing.Presentation.ChatController
---チャット機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

local notify = require("vibing.core.utils.notify")

---チャットウィンドウを開く（新規または既存ファイル）
---@param args string 引数文字列（位置指定またはファイルパス）
function M.handle_open(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  -- 引数をパース（位置指定 or ファイルパス）
  local position = nil
  local file_path = nil

  if args and args ~= "" then
    -- 位置キーワードのチェック
    if args == "current" or args == "right" or args == "left" or args == "top" or args == "bottom" or args == "back" then
      position = args
    else
      -- ファイルパスとして扱う
      file_path = args
    end
  end

  if file_path then
    -- 既存ファイルを開く
    local session = use_case.open_file(file_path)
    if session then
      view.render(session, position)
    else
      notify.error("Failed to load: " .. file_path, "Chat")
    end
  else
    -- 新規チャットを開く（位置指定あり/なし）
    local session = use_case.create_new()
    view.render(session, position)
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

---Worktreeでチャットを開く
---@param args string 引数文字列（position branch_name形式）
function M.handle_open_worktree(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")
  local worktree_manager = require("vibing.infrastructure.worktree.manager")

  -- 引数をパース（position branch_name）
  local parts = vim.split(args or "", "%s+")
  local position = nil
  local branch_name = nil

  -- 位置指定のバリデーション
  local valid_positions = { "right", "left", "top", "bottom", "back", "current" }
  if #parts >= 1 then
    -- 最初の引数が位置指定かチェック
    for _, pos in ipairs(valid_positions) do
      if parts[1] == pos then
        position = parts[1]
        break
      end
    end

    -- 位置指定がマッチしなかった場合、最初の引数をブランチ名として扱う
    if position then
      branch_name = parts[2]
    else
      branch_name = parts[1]
    end
  end

  if not branch_name or branch_name == "" then
    notify.error("Branch name is required", "Worktree")
    return
  end

  -- worktreeを準備
  local worktree_path = worktree_manager.prepare_worktree(branch_name)
  if not worktree_path then
    return
  end

  -- worktree用のチャットを開く（チャットファイルはメインリポジトリに保存）
  local session = use_case.create_new_for_worktree(worktree_path, branch_name)
  view.render(session, position)
end

return M
