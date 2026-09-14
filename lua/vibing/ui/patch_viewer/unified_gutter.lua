---@class Vibing.PatchViewer.UnifiedGutter
---unified表示の左端。`+` / `-` の記号と、その行が指すファイル上の行番号を出す。
---
---記号をここに出すからこそ、バッファ側は素のコードだけで済み、構文ハイライトが効く
---（`unified_lines` を参照）。行番号はバッファの行番号ではないので 'number' は落とし、
---'statuscolumn' に自前で書く。
local M = {}

local SIGN = { add = "+", del = "-" }
local SIGN_HL = { add = "VibingDiffAddSign", del = "VibingDiffDelSign" }

---'statuscolumn' から引くバッファごとの中身。バッファは選択のたびに作り直される
---@type table<number, { width: number, rows: { num: string, sign: string, hl: string }[] }>
M._rows = {}

---unifiedが上書きする前のウィンドウの見え方。side-by-side に戻す時に要る
---@type table<number, table<string, any>>
M._saved = {}

local OVERRIDDEN = { "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "cursorline" }

function M._sweep()
  for buf in pairs(M._rows) do
    if not vim.api.nvim_buf_is_valid(buf) then
      M._rows[buf] = nil
    end
  end
  for win in pairs(M._saved) do
    if not vim.api.nvim_win_is_valid(win) then
      M._saved[win] = nil
    end
  end
end

---画面行ごとに呼ばれる。失敗しても描画を壊さないよう静かに諦める。
---「今のバッファ」ではなく `g:statusline_winid` から引くのは、描画中のウィンドウが
---カレントとは限らないため（フロートが複数開いていると別のペインの行番号が出る）
---@return string
function M.statuscolumn()
  local win = vim.g.statusline_winid
  local drawn = (win and vim.api.nvim_win_is_valid(win)) and vim.api.nvim_win_get_buf(win)
    or vim.api.nvim_get_current_buf()

  local entry = M._rows[drawn]
  local row = entry and entry.rows[vim.v.lnum]
  if not row then
    return ""
  end

  local pad = string.rep(" ", math.max(0, entry.width - #row.num) + 1)
  return "%#VibingDiffGutter#" .. pad .. row.num .. " %#" .. row.hl .. "#" .. row.sign .. " "
end

---@param rows Vibing.PatchViewer.UnifiedLine[]
---@return { width: number, rows: table[] }
function M.build(rows)
  local width = 1
  for _, row in ipairs(rows) do
    if row.lnum then
      width = math.max(width, #tostring(row.lnum))
    end
  end

  local entry = { width = width, rows = {} }
  for i, row in ipairs(rows) do
    entry.rows[i] = {
      num = row.lnum and tostring(row.lnum) or "",
      sign = SIGN[row.kind] or " ",
      hl = SIGN_HL[row.kind] or "VibingDiffGutter",
    }
  end
  return entry
end

---@param win number
---@param buf number
---@param rows Vibing.PatchViewer.UnifiedLine[]
function M.apply(win, buf, rows)
  M._sweep()
  M._rows[buf] = M.build(rows)

  if not M._saved[win] then
    local saved = {}
    for _, name in ipairs(OVERRIDDEN) do
      saved[name] = vim.wo[win][name]
    end
    M._saved[win] = saved
  end

  pcall(function()
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].foldcolumn = "0"
    vim.wo[win].cursorline = true
    vim.wo[win].statuscolumn = "%{%v:lua.require'vibing.ui.patch_viewer.unified_gutter'.statuscolumn()%}"
  end)
end

---side-by-side に戻す時に呼ぶ。`win_after` は使い回されるので、戻し忘れると実ファイルに
---統一diffの行番号が出たままになる
---@param win number?
function M.reset(win)
  -- `M._saved[nil] = nil` はLuaのエラー（table index is nil）なので、先に弾く
  if not win then
    return
  end
  local saved = M._saved[win]
  M._saved[win] = nil
  if not saved or not vim.api.nvim_win_is_valid(win) then
    return
  end

  pcall(function()
    for _, name in ipairs(OVERRIDDEN) do
      vim.wo[win][name] = saved[name]
    end
  end)
end

return M
