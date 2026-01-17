---@class Vibing.ChatSession
---チャットセッションのドメインモデル
---ビジネスロジックに関わるデータとメタ情報を保持（UI表示から独立）
---@field session_id string? Claude SDKのセッションID
---@field file_path string? 保存先ファイルパス
---@field messages table[] 会話履歴
---@field frontmatter table YAMLフロントマターのデータ
---@field created_at string 作成日時
---@field updated_at string 更新日時
---@field cwd string? 作業ディレクトリ（worktree使用時に設定）
---@field task_ref string? Worktreeの相対パス（.worktrees/branch-name）
local ChatSession = {}
ChatSession.__index = ChatSession

---新しいチャットセッションを作成
---@param opts? table オプション
---@return Vibing.ChatSession
function ChatSession:new(opts)
  opts = opts or {}
  local instance = setmetatable({}, ChatSession)
  instance.session_id = opts.session_id
  instance.file_path = opts.file_path
  instance.messages = opts.messages or {}
  instance.frontmatter = opts.frontmatter or {}
  instance.created_at = opts.created_at or os.date("%Y-%m-%dT%H:%M:%S")
  instance.updated_at = opts.updated_at or os.date("%Y-%m-%dT%H:%M:%S")
  instance.cwd = opts.cwd
  instance.task_ref = opts.task_ref
  return instance
end

---ファイルからセッションを読み込む
---@param file_path string
---@return Vibing.ChatSession?
function ChatSession.load_from_file(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return nil
  end

  local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
  local content = vim.fn.readfile(file_path)
  local text = table.concat(content, "\n")
  local frontmatter = Frontmatter.parse(text) or {}

  -- session_idが有効な文字列の場合のみ設定
  local session_id = nil
  local sid = frontmatter.session_id
  if type(sid) == "string" and sid ~= "" and sid ~= "~" then
    session_id = sid
  end

  -- task_ref から cwd を復元（worktree が存在する場合のみ）
  local cwd = nil
  local task_ref = frontmatter.task_ref
  if task_ref and task_ref ~= "" then
    local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
    if vim.v.shell_error == 0 and git_root then
      local worktree_path = git_root .. "/" .. task_ref
      -- worktree ディレクトリが存在する場合のみ cwd を設定
      if vim.fn.isdirectory(worktree_path) == 1 then
        cwd = worktree_path
      end
    end
  end

  return ChatSession:new({
    session_id = session_id,
    file_path = file_path,
    frontmatter = frontmatter,
    created_at = frontmatter.created_at or os.date("%Y-%m-%dT%H:%M:%S"),
    updated_at = frontmatter.updated_at or os.date("%Y-%m-%dT%H:%M:%S"),
    cwd = cwd,
    task_ref = task_ref,
  })
end

---セッションIDを更新
---@param session_id string
function ChatSession:update_session_id(session_id)
  self.session_id = session_id
  self.frontmatter.session_id = session_id
  self.updated_at = os.date("%Y-%m-%dT%H:%M:%S")
  self.frontmatter.updated_at = self.updated_at
end

---セッションIDを取得
---@return string?
function ChatSession:get_session_id()
  return self.session_id
end

---ファイルパスを設定
---@param file_path string
function ChatSession:set_file_path(file_path)
  self.file_path = file_path
end

---ファイルパスを取得
---@return string?
function ChatSession:get_file_path()
  return self.file_path
end

---フロントマターを取得
---@return table
function ChatSession:get_frontmatter()
  return self.frontmatter
end

---フロントマターのフィールドを更新
---@param key string
---@param value any
function ChatSession:update_frontmatter(key, value)
  self.frontmatter[key] = value
  self.updated_at = os.date("%Y-%m-%dT%H:%M:%S")
  self.frontmatter.updated_at = self.updated_at
end

---作業ディレクトリを取得
---@return string?
function ChatSession:get_cwd()
  return self.cwd
end

---タスク参照（worktree相対パス）を取得
---@return string?
function ChatSession:get_task_ref()
  return self.task_ref
end

return ChatSession
