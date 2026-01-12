---@class Vibing.Application.ChatUseCase
---チャット機能のアプリケーション層Use Case
---ビジネスロジックのみを担当し、Presentation層に依存しない
local M = {}

local ChatSession = require("vibing.domain.chat.session")

---現在アクティブなセッション
---@type Vibing.ChatSession?
M._current_session = nil

---新しいチャットセッションを作成
---@return Vibing.ChatSession
function M.create_new()
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 新しいセッションを作成
  local session = ChatSession:new({
    frontmatter = {
      ["vibing.nvim"] = true,
      created_at = os.date("%Y-%m-%dT%H:%M:%S"),
      mode = config.agent and config.agent.default_mode or "code",
      model = config.agent and config.agent.default_model or "sonnet",
      permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
      permissions_allow = config.permissions and config.permissions.allow or {},
      permissions_deny = config.permissions and config.permissions.deny or {},
    },
  })

  -- ファイルパスを設定
  local save_location_type = config.chat.save_location_type or "project"
  local save_path
  if save_location_type == "project" then
    save_path = vim.fn.getcwd() .. "/.vibing/chat/"
  elseif save_location_type == "user" then
    save_path = vim.fn.stdpath("data") .. "/vibing/chats/"
  else
    save_path = config.chat.save_dir or (vim.fn.getcwd() .. "/.vibing/chat/")
  end
  if not save_path:match("/$") then
    save_path = save_path .. "/"
  end

  vim.fn.mkdir(save_path, "p")
  local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
  session:set_file_path(save_path .. filename)

  M._current_session = session
  return session
end

---指定されたディレクトリで新しいチャットセッションを作成
---@param directory string 作業ディレクトリのパス
---@return Vibing.ChatSession
function M.create_new_in_directory(directory)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- 新しいセッションを作成
  local session = ChatSession:new({
    frontmatter = {
      ["vibing.nvim"] = true,
      created_at = os.date("%Y-%m-%dT%H:%M:%S"),
      mode = config.agent and config.agent.default_mode or "code",
      model = config.agent and config.agent.default_model or "sonnet",
      permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
      permissions_allow = config.permissions and config.permissions.allow or {},
      permissions_deny = config.permissions and config.permissions.deny or {},
    },
  })

  -- ディレクトリを正規化
  local normalized_dir = vim.fn.fnamemodify(directory, ":p")
  if not normalized_dir:match("/$") then
    normalized_dir = normalized_dir .. "/"
  end

  -- ファイルパスを設定（指定されたディレクトリ内）
  local save_path = normalized_dir .. ".vibing/chat/"
  vim.fn.mkdir(save_path, "p")
  local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
  session:set_file_path(save_path .. filename)

  M._current_session = session
  return session
end

---既存のチャットファイルを開く
---@param file_path string ファイルパス
---@return Vibing.ChatSession?
function M.open_file(file_path)
  local session = ChatSession.load_from_file(file_path)
  if session then
    M._current_session = session
    return session
  end
  return nil
end

---現在のセッションを取得、存在しない場合は新規作成
---@return Vibing.ChatSession
function M.get_or_create_session()
  if M._current_session then
    return M._current_session
  end
  return M.create_new()
end

---既存バッファにアタッチ（:eで開いたファイル用）
---@param bufnr number バッファ番号
---@param file_path string ファイルパス
function M.attach_to_buffer(bufnr, file_path)
  local view = require("vibing.presentation.chat.view")
  view.attach_to_buffer(bufnr, file_path)
end

return M
