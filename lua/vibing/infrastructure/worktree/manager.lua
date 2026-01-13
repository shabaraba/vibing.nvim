---@class Vibing.Infrastructure.Worktree.Manager
---Git worktreeの作成と管理を担当するモジュール
---worktreeの作成、存在確認、環境セットアップを行う
local M = {}

local notify = require("vibing.core.utils.notify")

---worktreeのベースディレクトリを取得
---@return string worktreeベースディレクトリのパス
local function get_worktree_base()
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then
    return nil
  end
  local git_root = handle:read("*l") -- 最初の行のみ読み込む
  handle:close()

  -- パスが/で始まっているかチェック（絶対パスであることを確認）
  if not git_root or not git_root:match("^/") then
    return nil
  end
  return git_root .. "/.worktrees"
end

---指定されたブランチのworktreeパスを取得
---@param branch_name string ブランチ名
---@return string? worktreeのフルパス（gitルートが見つからない場合はnil）
function M.get_worktree_path(branch_name)
  local base = get_worktree_base()
  if not base then
    return nil
  end
  return base .. "/" .. branch_name
end

---worktreeが既に存在するかチェック
---@param branch_name string ブランチ名
---@return boolean 存在する場合true
function M.worktree_exists(branch_name)
  local worktree_path = M.get_worktree_path(branch_name)
  if not worktree_path then
    return false
  end

  -- git worktree listで確認
  local worktrees = vim.fn.systemlist("git worktree list --porcelain")
  for _, line in ipairs(worktrees) do
    if line:match("^worktree " .. vim.pesc(worktree_path)) then
      return true
    end
  end

  return false
end

---git worktreeを作成
---@param branch_name string ブランチ名
---@param worktree_path string worktreeのパス
---@return boolean 成功した場合true
local function create_worktree_internal(branch_name, worktree_path)
  -- ブランチが既に存在するかチェック
  local branches = vim.fn.systemlist("git branch --list " .. branch_name)
  local branch_exists = #branches > 0 and branches[1] ~= ""

  local cmd
  if branch_exists then
    -- 既存ブランチでworktreeを作成
    cmd = string.format("git worktree add %s %s", vim.fn.shellescape(worktree_path), branch_name)
  else
    -- 新しいブランチを作成してworktreeを作成
    cmd = string.format("git worktree add -b %s %s", branch_name, vim.fn.shellescape(worktree_path))
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    notify.error("Failed to create worktree: " .. result, "Worktree")
    return false
  end

  return true
end

---worktree環境のセットアップ（必要なファイルをコピー）
---@param worktree_path string worktreeのパス
---@return boolean 成功した場合true
local function setup_environment(worktree_path)
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then
    notify.error("Failed to get git root", "Worktree")
    return false
  end
  local git_root = handle:read("*l")
  handle:close()

  if not git_root or not git_root:match("^/") then
    notify.error("Failed to get git root", "Worktree")
    return false
  end

  -- コピーが必要なファイル/ディレクトリのリスト
  local items_to_copy = {
    ".gitignore",
    ".nvmrc",
    ".node-version",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "tsconfig.json",
    "tsconfig.*.json",
    ".eslintrc*",
    ".prettierrc*",
    "jest.config.*",
    "vitest.config.*",
    ".editorconfig",
  }

  local errors = {}

  for _, item in ipairs(items_to_copy) do
    -- globパターンをサポート
    local matches = vim.fn.glob(git_root .. "/" .. item, false, true)
    for _, source in ipairs(matches) do
      local relative_path = source:sub(#git_root + 2) -- git_root/を除く
      local dest = worktree_path .. "/" .. relative_path

      -- 親ディレクトリが存在しない場合は作成
      local dest_dir = vim.fn.fnamemodify(dest, ":h")
      if vim.fn.isdirectory(dest_dir) == 0 then
        vim.fn.mkdir(dest_dir, "p")
      end

      -- コピー実行（-pで属性も保持）
      local cp_cmd = string.format("cp -rp %s %s", vim.fn.shellescape(source), vim.fn.shellescape(dest))
      local result = vim.fn.system(cp_cmd)
      if vim.v.shell_error ~= 0 then
        table.insert(errors, string.format("Failed to copy %s: %s", relative_path, result))
      end
    end
  end

  if #errors > 0 then
    notify.warn("Some files could not be copied:\n" .. table.concat(errors, "\n"), "Worktree")
  end

  return true
end

---node_modulesのセットアップ（シンボリックリンク作成）
---@param worktree_path string worktreeのパス
---@return boolean 成功した場合true
local function setup_node_modules(worktree_path)
  local handle = io.popen("git rev-parse --show-toplevel 2>/dev/null")
  if not handle then
    return false
  end
  local git_root = handle:read("*l")
  handle:close()

  if not git_root or not git_root:match("^/") then
    return false
  end

  local main_node_modules = git_root .. "/node_modules"
  local worktree_node_modules = worktree_path .. "/node_modules"

  -- メインのnode_modulesが存在する場合のみシンボリックリンク作成
  if vim.fn.isdirectory(main_node_modules) == 1 then
    local ln_cmd = string.format("ln -sf %s %s", vim.fn.shellescape(main_node_modules), vim.fn.shellescape(worktree_node_modules))
    local result = vim.fn.system(ln_cmd)
    if vim.v.shell_error ~= 0 then
      notify.warn("Failed to link node_modules: " .. result, "Worktree")
      return false
    end
    return true
  end

  return false
end

---worktreeを準備（存在チェック、作成、環境セットアップ）
---@param branch_name string ブランチ名
---@return string? worktreeのパス（失敗した場合はnil）
function M.prepare_worktree(branch_name)
  local worktree_path = M.get_worktree_path(branch_name)
  if not worktree_path then
    notify.error("Not in a git repository", "Worktree")
    return nil
  end

  if M.worktree_exists(branch_name) then
    notify.info("Using existing worktree: " .. worktree_path, "Worktree")
    return worktree_path
  end

  -- worktreeベースディレクトリを作成
  local base = get_worktree_base()
  vim.fn.mkdir(base, "p")

  notify.info("Creating new worktree: " .. worktree_path, "Worktree")

  -- worktreeを作成
  if not create_worktree_internal(branch_name, worktree_path) then
    return nil
  end

  -- 環境セットアップ
  if not setup_environment(worktree_path) then
    notify.warn("Environment setup completed with warnings", "Worktree")
  end

  -- node_modulesのシンボリックリンク作成
  if setup_node_modules(worktree_path) then
    notify.info("Linked node_modules from main worktree", "Worktree")
  end

  notify.info("Worktree ready: " .. worktree_path, "Worktree")
  return worktree_path
end

---worktreeを削除
---@param branch_name string ブランチ名
---@return boolean 成功した場合true
function M.remove_worktree(branch_name)
  local worktree_path = M.get_worktree_path(branch_name)
  if not worktree_path then
    notify.error("Not in a git repository", "Worktree")
    return false
  end

  if not M.worktree_exists(branch_name) then
    notify.warn("Worktree does not exist: " .. worktree_path, "Worktree")
    return false
  end

  local cmd = string.format("git worktree remove %s", vim.fn.shellescape(worktree_path))
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    notify.error("Failed to remove worktree: " .. result, "Worktree")
    return false
  end

  notify.info("Worktree removed: " .. worktree_path, "Worktree")
  return true
end

---全てのworktreeをリスト表示
---@return table worktreeのリスト {path: string, branch: string, commit: string}[]
function M.list_worktrees()
  local worktrees = {}
  local lines = vim.fn.systemlist("git worktree list --porcelain")

  local current = {}
  for _, line in ipairs(lines) do
    if line:match("^worktree ") then
      current.path = line:sub(10) -- "worktree "の後
    elseif line:match("^branch ") then
      current.branch = line:sub(8) -- "branch "の後
    elseif line:match("^HEAD ") then
      current.commit = line:sub(6) -- "HEAD "の後
    elseif line == "" and current.path then
      table.insert(worktrees, current)
      current = {}
    end
  end

  -- 最後のエントリ
  if current.path then
    table.insert(worktrees, current)
  end

  return worktrees
end

return M
