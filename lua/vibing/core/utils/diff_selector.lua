---@class Vibing.Utils.DiffSelector
---patchファイルが見つからない場合のdiff表示フォールバックを管理
local M = {}

---diff内容をスクラッチバッファに表示
---@param output string diff出力
local function show_diff_buffer(output)
  local Factory = require("vibing.infrastructure.ui.factory")
  local buf = Factory.create_buffer({
    buftype = "nofile",
    bufhidden = "wipe",
    filetype = "diff",
    modifiable = true,
  })

  local lines = vim.split(output, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.cmd("vsplit")
  vim.api.nvim_win_set_buf(0, buf)

  vim.keymap.set("n", "q", function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, {
    buffer = buf,
    noremap = true,
    silent = true,
  })
end

---ファイルのgit diffを表示
---追跡済みならHEAD（無ければindex）との比較、未追跡・リポジトリ外なら
---git diff --no-index /dev/null でファイル全体を新規追加として表示する
---@param file_path string ファイルパス（絶対パス）
local function show_git_diff(file_path)
  local abs = vim.fn.fnamemodify(file_path, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")

  local tracked = vim.system({ "git", "ls-files", "--error-unmatch", "--", abs }, { cwd = dir, text = true }):wait()

  local result
  if tracked.code == 0 then
    result = vim.system({ "git", "diff", "HEAD", "--", abs }, { cwd = dir, text = true }):wait()
    if result.code ~= 0 then
      -- HEADが無い場合（初回コミット前）はindexとの比較にフォールバック
      result = vim.system({ "git", "diff", "--cached", "--", abs }, { cwd = dir, text = true }):wait()
    end
  else
    -- 未追跡ファイル・リポジトリ外: /dev/nullと比較して全体を新規として表示
    -- （--no-indexは差分ありで終了コード1を返すので正常扱い）
    result = vim.system({ "git", "diff", "--no-index", "--", "/dev/null", abs }, { cwd = dir, text = true }):wait()
    if result.code == 1 then
      result.code = 0
    end
  end

  if result.code ~= 0 then
    vim.notify("[vibing] git diff failed: " .. vim.trim(result.stderr or ""), vim.log.levels.ERROR)
    return
  end

  local output = result.stdout or ""
  if output == "" or output:match("^%s*$") then
    vim.notify("[vibing] No changes to show", vim.log.levels.INFO)
    return
  end

  show_diff_buffer(output)
end

-- テスト用エクスポート
M._show_git_diff = function(file_path)
  return show_git_diff(file_path)
end

---ファイルのdiffを表示
---
---リクエストごとのpatchファイルが見つからなかったときのフォールバック。patchはターン単位の
---差分だが、こちらはHEAD（またはindex）との差分なので、そのターンだけの変更とは限らない。
---@param file_path string ファイルパス（絶対パス）
---@param session_id? string セッションID（未使用、互換性のため保持）
---@param cwd? string 作業ディレクトリ（未使用、互換性のため保持）
function M.show_diff(file_path, session_id, cwd)
  show_git_diff(file_path)
end

return M
