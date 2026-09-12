---@class Vibing.Utils.GitHeadText
---HEAD時点のファイル内容を行配列で返す。
---
---`patch_text.lua` がターン単位の参照テキストを作るのに対し、こちらはそのターンのpatchが
---見つからなかったときのフォールバック用。HEADとの差分なので、そのターンだけの変更とは
---限らない — 呼び出し側はそれをユーザーに伝える責任がある。
local M = {}

---@param file_path string
---@return string[] lines HEADに無いファイル（未追跡・リポジトリ外）は空テーブル＝全体が新規
function M.lines(file_path)
  local abs = vim.fn.fnamemodify(file_path, ":p")
  local dir = vim.fn.fnamemodify(abs, ":h")
  if vim.fn.isdirectory(dir) ~= 1 then
    return {}
  end

  local root = vim.system({ "git", "rev-parse", "--show-toplevel" }, { cwd = dir, text = true }):wait()
  local top = vim.trim(root.stdout or "")
  if root.code ~= 0 or top == "" then
    return {}
  end

  -- `--show-toplevel` はシンボリックリンクを解決した実パスを返すので、相対パスも同じ
  -- 解決を通したものから切り出す。macOSの `/tmp` → `/private/tmp` がこれに当たる
  local resolved = vim.fn.resolve(abs)
  if resolved:sub(1, #top + 1) ~= top .. "/" then
    return {}
  end
  local rel = resolved:sub(#top + 2)

  local show = vim.system({ "git", "show", "HEAD:" .. rel }, { cwd = top, text = true }):wait()
  if show.code ~= 0 then
    return {}
  end

  local lines = vim.split(show.stdout or "", "\n", { plain = true })
  -- 末尾の改行が生む空要素は行ではない
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

return M
