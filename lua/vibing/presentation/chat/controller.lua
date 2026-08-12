---@class Vibing.Presentation.ChatController
---チャット機能のPresentation層Controller
---ユーザー入力を受け取り、Use Caseを呼び出し、Viewに結果を渡す責務を持つ
local M = {}

local notify = require("vibing.core.utils.notify")

---コマンド引数として受け付けるウィンドウ位置
local VALID_POSITIONS = { current = true, right = true, left = true, top = true, bottom = true, back = true }

---位置指定のみを取る引数をパースする（不正値は警告してデフォルトに落とす）
---@param args string?
---@return string? position
local function parse_position(args)
  if not args or args == "" then
    return nil
  end
  if VALID_POSITIONS[args] then
    return args
  end
  notify.warn("Invalid position: " .. args .. ". Using default.")
  return nil
end

---チャットウィンドウを開く（新規または既存ファイル）
---@param args string 引数文字列（位置指定またはファイルパス）
function M.handle_open(args)
  local use_case = require("vibing.application.chat.use_case")
  local view = require("vibing.presentation.chat.view")

  -- 引数をパース（位置指定 or ファイルパス）
  local position = nil
  local file_path = nil

  if args and args ~= "" then
    if VALID_POSITIONS[args] then
      position = args
    else
      -- 位置キーワードでなければファイルパスとして扱う
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

---チャット履歴からサマリーを生成してバッファに挿入
function M.handle_summarize()
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.warn("Not in a vibing chat buffer")
    return
  end

  local use_case = require("vibing.application.chat.use_case")
  use_case.generate_and_insert_summary(current_view)
end

---チャットをフォーク
---@param args string? 引数文字列（位置指定のみ）
function M.handle_fork(args)
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.error("Not in a vibing chat buffer")
    return
  end

  local position = parse_position(args)

  -- フォークセッションを作成
  local fork_use_case = require("vibing.application.chat.use_cases.fork")
  local fork_session = fork_use_case.execute(current_view)

  if fork_session then
    view.render(fork_session, position)
  else
    notify.error("Failed to fork chat session")
  end
end

---このチャットが起動したsubagentとの継続対話を開く
---@param args string? 引数文字列（位置指定のみ）
function M.handle_subagent_chat(args)
  local view = require("vibing.presentation.chat.view")
  local current_view = view.get_current()

  if not current_view then
    notify.error("Not in a vibing chat buffer")
    return
  end

  local finder = require("vibing.presentation.chat.modules.subagent_finder")
  local refs = finder.find_all(current_view.buf)

  if #refs == 0 then
    notify.error("No resumable subagent in this chat (built-in Explore/Plan agents cannot be resumed)")
    return
  end

  local position = parse_position(args)

  local function open(ref)
    local use_case = require("vibing.application.chat.use_cases.subagent_chat")
    local session, existing_path = use_case.execute(current_view, ref.agent_id)

    if existing_path then
      notify.info("Reopening the existing chat for this subagent")
      vim.cmd.edit(vim.fn.fnameescape(existing_path))
      return
    end
    if session then
      view.render(session, position)
    end
  end

  if #refs == 1 then
    open(refs[1])
    return
  end

  vim.ui.select(refs, {
    prompt = "Continue which subagent?",
    format_item = finder.describe,
  }, function(choice)
    if choice then
      open(choice)
    end
  end)
end

return M
