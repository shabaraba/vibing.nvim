---@class Vibing.Presentation.FileUnderCursor
---`gf`（カーソル下のファイルを開く）が「どのファイルのことか」を決める三段。
---
---順序は入れ替えられない。`<cfile>` は `isfname` に従うだけなので、
---`[ラベル](path.lua)` のラベルの上ではラベルの文字列を拾ってしまう。リンク記法の
---判定を先に置かないと、記法の中なのに関係ないパスを開くか、何も開かないことになる。
local M = {}

---@param buf number チャットバッファ番号
---@return string? 開くべきパス、または `[Buffer N]` 識別子
---@return number? ジャンプする行番号
function M.resolve(buf)
  local FilePath = require("vibing.core.utils.file_path")

  -- 1. `### Modified Files` 節のパス行。削除されたファイルも返るので存在確認はしない
  local in_section = FilePath.is_cursor_on_file_path(buf)
  if in_section then
    return in_section
  end

  -- 2. Markdown のインラインリンク。ラベルの上でも効く
  local linked, lnum = FilePath.find_link_target_under_cursor(buf)
  if linked then
    return linked, lnum
  end

  -- 3. それ以外は `<cfile>`
  local cfile = vim.fn.expand("<cfile>")
  if cfile == "" then
    return nil
  end
  local expanded = vim.fn.expand(cfile)
  if vim.fn.filereadable(expanded) == 1 then
    return expanded
  end
  return nil
end

return M
