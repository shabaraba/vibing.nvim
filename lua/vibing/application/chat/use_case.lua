---@class Vibing.Application.ChatUseCase
---チャット機能のアプリケーション層Use Case
---ビジネスロジックのみを担当し、Presentation層に依存しない
local M = {}

local ChatSession = require("vibing.domain.chat.session")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

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

  local save_path = FileManager.get_save_directory(config.chat)
  vim.fn.mkdir(save_path, "p")
  local filename = FileManager.generate_unique_filename()
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
