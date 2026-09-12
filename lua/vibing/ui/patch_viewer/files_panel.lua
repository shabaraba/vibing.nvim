---@class Vibing.PatchViewer.FilesPanel
---左ペインのファイル一覧。
---
---1行に収めるものは `▎ アイコン 名前 … 状態 +N -M` で、幅が足りなければ名前を詰める。
---フルパスはここではなく Before/After ペインのタイトルに出る（20%幅に入らないため）。
---
---**先頭2行がヘッダなのは固定**。`init.lua` のカーソル移動が `選択位置 + 2` 行目を指す。
local M = {}

local icons = require("vibing.ui.patch_viewer.icons")

local NS = vim.api.nvim_create_namespace("vibing_patch_viewer")

---`s` の行はいま押すと **何になるか** を書く。別に現在の表示形式を示す欄を持つより、
---押す前に分かる方が短くて確実
---@param state Vibing.PatchViewer.State
---@return string[]
local function help_lines(state)
  local lines = {
    "j/k    Navigate files",
    "<CR>/o Open the real file",
    "<Tab>  Switch pane",
  }

  if state.layout == "unified" then
    table.insert(lines, "s      Side-by-side view")
  else
    table.insert(lines, "s      Unified view")
    table.insert(lines, "]c/[c  Next/prev hunk")
    table.insert(lines, "do/dp  Get/put a hunk")
    table.insert(lines, "zo/zc  Open/close a fold")
  end

  table.insert(lines, "r/R    Revert file / all")
  table.insert(lines, "q      Quit")
  return lines
end

---@param segments table[]
---@param text string?
---@param hl string?
local function push(segments, text, hl)
  if text and text ~= "" then
    table.insert(segments, { text = text, hl = hl })
  end
end

---セグメントを1行の文字列と、そのバイト範囲のハイライト指定に畳む
---@param segments table[]
---@return string line
---@return table[] highlights
local function flatten(segments)
  local parts, highlights, col = {}, {}, 0
  for _, segment in ipairs(segments) do
    local len = #segment.text
    if segment.hl then
      table.insert(highlights, { hl = segment.hl, from = col, to = col + len })
    end
    col = col + len
    table.insert(parts, segment.text)
  end
  return table.concat(parts), highlights
end

---@param stats table
---@return string
local function counts_text(stats)
  local parts = {}
  if stats.added > 0 then
    table.insert(parts, "+" .. stats.added)
  end
  if stats.removed > 0 then
    table.insert(parts, "-" .. stats.removed)
  end
  return table.concat(parts, " ")
end

---@param state Vibing.PatchViewer.State
---@param idx number
---@param width number ペインの内側の幅
---@return table[] segments
function M._entry(state, idx, width)
  local path = state.files[idx]
  local stats = (state.stats or {})[idx] or { status = "M", added = 0, removed = 0 }
  local selected = idx == state.selected_idx
  local icon, icon_hl = icons.get(path)

  local marker = selected and "▎ " or "  "
  local lead = marker .. (icon and (icon .. " ") or "")
  local lead_width = vim.fn.strwidth(lead)

  -- 変更だけの `M` は大半なので出さない。追加と削除は一目で分かる方がいい
  local status = (stats.status ~= "M") and stats.status or nil
  local tail = (status and (status .. " ") or "") .. counts_text(stats)
  local tail_width = vim.fn.strwidth(tail)

  local name = vim.fn.fnamemodify(path, ":t")
  local room = math.max(1, width - lead_width - tail_width - 1)
  if vim.fn.strwidth(name) > room then
    name = vim.fn.strcharpart(name, 0, math.max(1, room - 1)) .. "…"
  end

  local segments = {}
  push(segments, marker, selected and "Title" or nil)
  push(segments, icon and (icon .. " ") or nil, icon_hl)
  push(segments, name)
  -- 選択行のハイライトが途中で切れないよう、行はペイン幅いっぱいまで埋める
  push(segments, string.rep(" ", math.max(1, width - lead_width - vim.fn.strwidth(name) - tail_width)))
  push(segments, status and (status .. " ") or nil, status == "A" and "Added" or "Removed")
  if stats.added > 0 then
    push(segments, "+" .. stats.added, "Added")
    push(segments, stats.removed > 0 and " " or nil)
  end
  if stats.removed > 0 then
    push(segments, "-" .. stats.removed, "Removed")
  end

  return segments
end

---@param state Vibing.PatchViewer.State
function M.render(state)
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local width = 30
  if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
    width = vim.api.nvim_win_get_width(state.win_files)
  end

  local lines = { string.format(" Files (%d)", #state.files), "" }
  local highlights = { { row = 0, hl = "Title", from = 0, to = -1 } }

  for idx = 1, #state.files do
    local line, line_hls = flatten(M._entry(state, idx, width - 1))
    table.insert(lines, line)
    local row = #lines - 1
    if idx == state.selected_idx then
      table.insert(highlights, { row = row, hl = "CursorLine", from = 0, to = -1 })
    end
    for _, item in ipairs(line_hls) do
      table.insert(highlights, { row = row, hl = item.hl, from = item.from, to = item.to })
    end
  end

  table.insert(lines, "")
  table.insert(lines, string.rep("─", math.max(1, width - 1)))
  for _, help in ipairs(help_lines(state)) do
    table.insert(lines, " " .. help)
    table.insert(highlights, { row = #lines - 1, hl = "Comment", from = 0, to = -1 })
  end

  vim.bo[state.buf_files].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.bo[state.buf_files].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.buf_files, NS, 0, -1)
  for _, item in ipairs(highlights) do
    -- `to = -1`（行末まで）は extmark では受け取れないので、その行のバイト長に直す
    local to = item.to >= 0 and item.to or #lines[item.row + 1]
    pcall(vim.api.nvim_buf_set_extmark, state.buf_files, NS, item.row, item.from, {
      end_row = item.row,
      end_col = to,
      hl_group = item.hl,
    })
  end
end

return M
