---@class Vibing.Utils.Mote.Context
---moteコンテキストの名前生成とパス管理
local M = {}

---文字列をmoteの命名ルールに従ってサニタイズ
---ASCII文字、数字、ハイフン、アンダースコアのみ許可
---@param name string 元の名前
---@return string サニタイズされた名前
local function sanitize_name(name)
  return name
    :gsub("[/\\:]", "-")
    :gsub("%s+", "-")
    :gsub("[^%w%-%_%.]+", "-")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")
end

---元のブランチ名から短いハッシュを生成（衝突防止用）
---@param original_name string 元のブランチ名
---@return string 8文字のハッシュ
local function generate_hash(original_name)
  local hash = 0
  for i = 1, #original_name do
    hash = (hash * 31 + string.byte(original_name, i)) % 2147483647
  end
  return string.format("%08x", hash):sub(1, 8)
end

---Worktree固有のコンテキスト名を生成
---mote v0.2.0: --context API対応
---
---同じworktree内の全セッションは同じmote contextを共有します。
---これにより、worktree内での作業履歴を一貫して追跡できます。
---
---衝突防止のため、元のブランチ名のハッシュをサフィックスとして追加します。
---例: feature/task → vibing-worktree-feature-task-a1b2c3d4
---     feature-task → vibing-worktree-feature-task-e5f6g7h8
---
---@param context_prefix string コンテキスト名のプレフィックス
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return string Worktree固有のコンテキスト名
function M.build_name(context_prefix, cwd)
  if cwd then
    local worktree_path = cwd:match("%.worktrees/(.+)")
    if worktree_path then
      local worktree_name = sanitize_name(worktree_path)
      local hash_suffix = generate_hash(worktree_path)
      return string.format("%s-worktree-%s-%s", context_prefix, worktree_name, hash_suffix)
    end
  end

  return string.format("%s-root", context_prefix)
end

---gitリポジトリ名からプロジェクト名を取得
---moteのコンテキスト命名ルールに従ってサニタイズ
---@return string|nil プロジェクト名（取得できない場合nil）
function M.get_project_name()
  local Git = require("vibing.core.utils.git")
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end

  local project_name = vim.fn.fnamemodify(git_root, ":t")
  return project_name
    :gsub("[^%w%-_]+", "-")
    :gsub("%-+", "-")
    :gsub("^%-", "")
    :gsub("%-$", "")
end

---プロジェクトローカルのcontext-dirパスを生成
---@param project string|nil プロジェクト名
---@param context string コンテキスト名
---@return string|nil context-dirのパス（git rootが取得できない場合nil）
function M.build_dir_path(project, context)
  local Git = require("vibing.core.utils.git")
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end

  local project_name = project or "default"
  return git_root .. "/.vibing/mote/" .. project_name .. "/" .. context
end

---moteコンテキストが初期化されているかチェック
---@param project string? プロジェクト名
---@param context string? コンテキスト名
---@return boolean moteコンテキストが初期化されている場合true
function M.is_initialized(project, context)
  local Binary = require("vibing.core.utils.mote.binary")
  if not Binary.is_available() then
    return false
  end

  local context_dir = M.build_dir_path(project, context)
  if not context_dir then
    return false
  end

  local config_path = context_dir .. "/config.toml"
  return vim.fn.filereadable(config_path) == 1
end

return M
