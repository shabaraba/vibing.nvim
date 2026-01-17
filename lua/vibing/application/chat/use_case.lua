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

---指定されたディレクトリで新しいチャットセッションを作成
---@param directory string 作業ディレクトリのパス
---@return Vibing.ChatSession
function M.create_new_in_directory(directory)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- ディレクトリを正規化
  local normalized_dir = vim.fn.fnamemodify(directory, ":p")
  if not normalized_dir:match("/$") then
    normalized_dir = normalized_dir .. "/"
  end
  -- 末尾のスラッシュを削除（cwdとして使用）
  local cwd = normalized_dir:gsub("/$", "")

  -- 新しいセッションを作成
  -- NOTE: cwd is NOT saved to frontmatter (only exists in memory)
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
    cwd = cwd,  -- Set cwd in memory only
  })

  -- ファイルパスを設定（指定されたディレクトリ内）
  local save_path = normalized_dir .. ".vibing/chat/"
  vim.fn.mkdir(save_path, "p")
  local filename = FileManager.generate_unique_filename()
  session:set_file_path(save_path .. filename)

  M._current_session = session
  return session
end

---worktree用の新しいチャットセッションを作成
---チャットファイルはメインリポジトリの.vibing/worktrees/<branch>/に保存
---@param worktree_path string worktreeのパス
---@param branch_name string ブランチ名
---@return Vibing.ChatSession
function M.create_new_for_worktree(worktree_path, branch_name)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- worktreeのパスを正規化（cwdとして使用）
  local normalized_worktree = vim.fn.fnamemodify(worktree_path, ":p"):gsub("/$", "")

  -- メインリポジトリのルートを取得
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if vim.v.shell_error ~= 0 then
    require("vibing.core.utils.notify").error("Failed to get git root", "Chat")
    return M.create_new()
  end

  -- 新しいセッションを作成
  -- NOTE: cwd is NOT saved to frontmatter (only exists in memory)
  -- This prevents issues when reopening chat after worktree deletion
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
    cwd = normalized_worktree,  -- Set cwd in memory only
  })

  -- ファイルパスをメインリポジトリ内の.vibing/worktrees/<branch>/に設定
  local save_path = git_root .. "/.vibing/worktrees/" .. branch_name .. "/"
  vim.fn.mkdir(save_path, "p")
  local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
  session:set_file_path(save_path .. filename)

  M._current_session = session
  return session
end

---worktree用の新しいチャットセッションを作成
---チャットファイルはメインリポジトリの.vibing/worktrees/<branch>/に保存
---@param worktree_path string worktreeのパス
---@param branch_name string ブランチ名
---@return Vibing.ChatSession
function M.create_new_for_worktree(worktree_path, branch_name)
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- worktreeのパスを正規化（cwdとして使用）
  local normalized_worktree = vim.fn.fnamemodify(worktree_path, ":p"):gsub("/$", "")

  -- メインリポジトリのルートを取得
  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  if vim.v.shell_error ~= 0 then
    require("vibing.core.utils.notify").error("Failed to get git root", "Chat")
    return M.create_new()
  end

  -- 新しいセッションを作成
  -- NOTE: cwd is NOT saved to frontmatter (only exists in memory)
  -- This prevents issues when reopening chat after worktree deletion
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
    cwd = normalized_worktree,  -- Set cwd in memory only
  })

  -- ファイルパスをメインリポジトリ内の.vibing/worktrees/<branch>/に設定
  local save_path = git_root .. "/.vibing/worktrees/" .. branch_name .. "/"
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
