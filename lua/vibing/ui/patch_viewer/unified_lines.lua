---@class Vibing.PatchViewer.UnifiedLines
---統一diffのテキストを「バッファに置く行」と「その行が何なのか」へ分解する。
---
---行頭の `+` / `-` はここで落とす。残したままだと、その行はもうその言語として文法的に
---壊れているので構文ハイライトが当たらない。記号は `kind` として持ち上げ、描画側が
---サイン列に出す。ディスク上の `.patch` には手を触れないので `git apply` は従来どおり。
---
---副作用が無いので、描画を動かさずにそのままテストできる。
local M = {}

local char_diff = require("vibing.ui.patch_viewer.char_diff")

---パスも内容もFilesペインとペインタイトルで分かっているヘッダ。素のコードのあいだに
---挟まると読みにくいだけなので落とす
local DROPPED = {
  "^diff %-%-git ",
  "^diff %-%-mote ",
  "^index ",
  "^%-%-%- ",
  "^%+%+%+ ",
}

---@param line string
---@param patterns string[]
---@return boolean
local function matches_any(line, patterns)
  for _, pattern in ipairs(patterns) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

---連続する削除の塊と、その直後の追加の塊を突き合わせて、変わった文字の範囲を入れる
---@param lines Vibing.PatchViewer.UnifiedLine[]
local function pair_runs(lines)
  local i = 1
  while i <= #lines do
    if lines[i].kind ~= "del" then
      i = i + 1
    else
      local del_start = i
      while lines[i] and lines[i].kind == "del" do
        i = i + 1
      end
      local add_start = i
      while lines[i] and lines[i].kind == "add" do
        i = i + 1
      end

      -- 行数が1対1で揃っている塊だけ。食い違う塊を機械的に上から突き合わせると、
      -- 無関係な行どうしを比べて出鱈目な範囲が濃く着く
      local count = add_start - del_start
      if count > 0 and count == i - add_start then
        for n = 0, count - 1 do
          local del_line, add_line = lines[del_start + n], lines[add_start + n]
          del_line.char_ranges, add_line.char_ranges = char_diff.ranges(del_line.text, add_line.text)
        end
      end
    end
  end
end

---@class Vibing.PatchViewer.UnifiedLine
---@field text string バッファに置く行（`+` / `-` は落としてある）
---@field kind "add"|"del"|"context"|"hunk"|"info"
---@field lnum number? 指しているファイル上の行番号。`del` は変更前、それ以外は変更後
---@field char_ranges {start_col: number, end_col: number}[]? 変わった文字のバイト範囲

---@param file_diff string?
---@return Vibing.PatchViewer.UnifiedLine[]
function M.build(file_diff)
  local out = {}
  -- 最初の `@@` より前だけをヘッダとして扱う。`--- foo` は「`-- foo` を消した行」でもあり、
  -- 行の形だけで判別すると本文を1行取りこぼす
  local in_hunk = false
  local old_lnum, new_lnum = 0, 0

  for _, line in ipairs(vim.split(file_diff or "", "\n", { plain = true })) do
    local hunk_old, hunk_new = line:match("^@@ %-(%d+)[,%d]* %+(%d+)")
    if hunk_old then
      in_hunk = true
      old_lnum, new_lnum = tonumber(hunk_old), tonumber(hunk_new)
      table.insert(out, { text = line, kind = "hunk" })
    elseif not in_hunk then
      -- 新規/削除/リネーム/バイナリは、出さないと何が起きたのか分からなくなる
      if not matches_any(line, DROPPED) and line ~= "" then
        table.insert(out, { text = line, kind = "info" })
      end
    elseif line:sub(1, 1) == "\\" then
      -- `\ No newline at end of file`
      table.insert(out, { text = line, kind = "info" })
    elseif line:sub(1, 1) == "+" then
      table.insert(out, { text = line:sub(2), kind = "add", lnum = new_lnum })
      new_lnum = new_lnum + 1
    elseif line:sub(1, 1) == "-" then
      table.insert(out, { text = line:sub(2), kind = "del", lnum = old_lnum })
      old_lnum = old_lnum + 1
    else
      -- 文脈行。空行が本当に空で来ることがあるので `sub(2)` に任せる
      table.insert(out, { text = line:sub(2), kind = "context", lnum = new_lnum })
      old_lnum = old_lnum + 1
      new_lnum = new_lnum + 1
    end
  end

  -- patch末尾の改行が空の文脈行になって、最後に1行余る
  if #out > 0 and out[#out].kind == "context" and out[#out].text == "" then
    table.remove(out)
  end

  pair_runs(out)
  return out
end

return M
