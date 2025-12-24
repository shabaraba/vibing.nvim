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

  -- deltaは一時的に無効化（カラーコードの問題を回避）
  local has_delta = false

  -- git diffコマンド実行（複数の方法を試す）
  local cmd
  local result

  -- 1. まずHEADとの差分を試す（既存ファイルの変更）
  cmd = string.format("git diff --no-color HEAD -- %s", vim.fn.shellescape(normalized_path))

  result = vim.fn.systemlist({ "sh", "-c", cmd })

  -- 2. 結果が空の場合、ステージング済みの変更を試す（新規ファイル等）
  if vim.v.shell_error == 0 and #result == 0 then
    cmd = string.format("git diff --no-color --cached -- %s", vim.fn.shellescape(normalized_path))
    result = vim.fn.systemlist({ "sh", "-c", cmd })
  end

  -- 3. それでも空の場合、working treeとindexの差分を試す
  if vim.v.shell_error == 0 and #result == 0 then
    cmd = string.format("git diff --no-color -- %s", vim.fn.shellescape(normalized_path))
    result = vim.fn.systemlist({ "sh", "-c", cmd })
  end

  if vim.v.shell_error ~= 0 then
    local lines = {
      "Error: Could not retrieve diff for " .. file_path,
      "Command: " .. cmd,
      "Exit code: " .. tostring(vim.v.shell_error),
      "Output:",
    }
    -- エラー出力を個別の行として追加
    for _, line in ipairs(result) do
      table.insert(lines, "  " .. line)
    end
    if #result == 0 then
      table.insert(lines, "  (empty)")
    end

    return {
      lines = lines,
      has_delta = false,
      error = true,
    }
  end

  -- 結果が空の場合はメッセージを表示
  if #result == 0 then
    return {
      lines = { "No changes detected for " .. file_path },
      has_delta = false,
      error = false,
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
