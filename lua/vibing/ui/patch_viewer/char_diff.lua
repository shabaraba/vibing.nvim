---@class Vibing.PatchViewer.CharDiff
---2行のあいだで「変わった文字」のバイト範囲を出す。
---
---side-by-side はこれを `diffopt` の `inline:char` から貰っているが、unified はペインが1枚
---しか無いので組み込みのdiffモードに入れられない。同じものをここで作る。
---
---`vim.diff` に **1文字を1行にした文字列** を渡すと、行単位のdiffがそのまま文字単位のdiffに
---なる。自前で共通の先頭/末尾を削る近似と違って、split側と同じ結果が出る。
local M = {}

---`vim.diff` は行数に対して二乗で効く。minifiedの1行のような極端な入力で固まらせない。
---越えた行は文字単位を諦めて、行全体の背景だけで見せる
local MAX_CHARS = 800

---マルチバイト安全に1文字ずつへ割る
---@param s string
---@return string[]
function M.chars(s)
  return vim.fn.split(s, "\\zs")
end

---@param chars string[]
---@param start_idx number 1始まりの文字位置
---@param count number
---@return number start_col 0始まりのバイト位置
---@return number end_col 終端の次のバイト位置
local function byte_range(chars, start_idx, count)
  local start_col = 0
  for i = 1, start_idx - 1 do
    start_col = start_col + #chars[i]
  end

  local end_col = start_col
  for i = start_idx, start_idx + count - 1 do
    end_col = end_col + #chars[i]
  end

  return start_col, end_col
end

---@param before string
---@param after string
---@return {start_col: number, end_col: number}[] del `before` の変わった範囲
---@return {start_col: number, end_col: number}[] add `after` の変わった範囲
function M.ranges(before, after)
  local a = M.chars(before)
  local b = M.chars(after)

  -- 片方が空の行は「全部消えた / 全部足した」なので、行全体の背景で足りる
  if #a == 0 or #b == 0 or #a > MAX_CHARS or #b > MAX_CHARS then
    return {}, {}
  end

  local ok, hunks = pcall(vim.diff, table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n", {
    result_type = "indices",
    algorithm = "histogram",
  })
  if not ok or type(hunks) ~= "table" then
    return {}, {}
  end

  local del, add = {}, {}
  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    -- 純粋な挿入/削除では片側の count が 0 になり、その時の start は「直前の位置」を指す。
    -- 範囲にはならないので触らない
    if count_a > 0 then
      local s, e = byte_range(a, start_a, count_a)
      table.insert(del, { start_col = s, end_col = e })
    end
    if count_b > 0 then
      local s, e = byte_range(b, start_b, count_b)
      table.insert(add, { start_col = s, end_col = e })
    end
  end

  return del, add
end

return M
