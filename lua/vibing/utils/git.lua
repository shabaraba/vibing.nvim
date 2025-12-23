---@class Vibing.Utils.Git
---Git操作のユーティリティ
---Inline Previewで使用するGit diff取得、checkout操作を提供
local M = {}

---Git管理下のプロジェクトかチェック
---@return boolean Git管理下の場合true
function M.is_git_repo()
  local result = vim.fn.system("git rev-parse --is-inside-work-tree 2>/dev/null")
  return vim.v.shell_error == 0
end

---単一ファイルのgit diffを取得
---deltaが利用可能な場合は自動的に使用
---@param file_path string ファイルパス（絶対パスまたは相対パス）
---@return table { lines: string[], has_delta: boolean, error: boolean? }
function M.get_diff(file_path)
  -- ファイルパスを正規化
  local normalized_path = vim.fn.fnamemodify(file_path, ":p")

  -- deltaの利用可能性をチェック
  local has_delta = vim.fn.executable("delta") == 1

  -- git diffコマンド実行
  local cmd
  if has_delta then
    cmd = string.format("git diff HEAD %s | delta", vim.fn.shellescape(normalized_path))
  else
    cmd = string.format("git diff HEAD %s", vim.fn.shellescape(normalized_path))
  end

  local result = vim.fn.systemlist({ "sh", "-c", cmd })

  if vim.v.shell_error ~= 0 then
    return {
      lines = { "Error: Could not retrieve diff for " .. file_path },
      has_delta = false,
      error = true,
    }
  end

  return {
    lines = result,
    has_delta = has_delta,
    error = false,
  }
end

---複数ファイルのgit diffを一括取得
---@param files string[] ファイルパスの配列
---@return table<string, table> { [filepath] = { lines, has_delta, error } }
function M.get_diffs(files)
  local diffs = {}

  for _, file in ipairs(files) do
    diffs[file] = M.get_diff(file)
  end

  return diffs
end

---ファイルをgit checkout HEADで元に戻す
---@param files string[] ファイルパスの配列
---@return table { success: boolean, errors: table[] }
function M.checkout_files(files)
  local errors = {}

  for _, file in ipairs(files) do
    local normalized_path = vim.fn.fnamemodify(file, ":p")
    local cmd = string.format("git checkout HEAD %s 2>&1", vim.fn.shellescape(normalized_path))
    local result = vim.fn.system(cmd)

    if vim.v.shell_error ~= 0 then
      table.insert(errors, {
        file = file,
        message = result:gsub("\n$", ""),
      })
    end
  end

  return {
    success = #errors == 0,
    errors = errors,
  }
end

return M
