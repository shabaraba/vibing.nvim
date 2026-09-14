---@class Vibing.PatchViewer.Unified
---統一diffを「素のコード + 背景の濃淡」で描く。side-by-side と同じ考え方で、前景色は
---触らず、行はうっすら、変わった文字だけ濃くする。
---
---`+` / `-` はバッファから落として左端に出す（`unified_lines` と `unified_gutter`）。
---おかげで元ファイルの filetype をそのまま当てられ、構文ハイライトが効く。
local M = {}

local highlights = require("vibing.ui.patch_viewer.highlights")
local unified_lines = require("vibing.ui.patch_viewer.unified_lines")
local gutter = require("vibing.ui.patch_viewer.unified_gutter")

local NS = vim.api.nvim_create_namespace("vibing_patch_viewer_unified")

local LINE_HL = { add = "VibingDiffAddLine", del = "VibingDiffDelLine" }
local TEXT_HL = { add = "VibingDiffAddText", del = "VibingDiffDelText" }

M.reset_window = gutter.reset

---@param buf number
---@param rows Vibing.PatchViewer.UnifiedLine[]
function M._decorate(buf, rows)
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)

  for i, row in ipairs(rows) do
    if LINE_HL[row.kind] then
      -- `line_hl_group` は行末より先まで塗るので、短い行でも帯が途切れない
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 0, { line_hl_group = LINE_HL[row.kind] })
      for _, range in ipairs(row.char_ranges or {}) do
        pcall(vim.api.nvim_buf_set_extmark, buf, NS, i - 1, range.start_col, {
          end_col = range.end_col,
          hl_group = TEXT_HL[row.kind],
        })
      end
    elseif row.kind == "hunk" or row.kind == "info" then
      -- ここだけは前景色も潰す。コードではないものに構文ハイライトが当たったまま残ると、
      -- `@@` の行がキーワードや数値の色で騒がしくなる
      vim.api.nvim_buf_set_extmark(buf, NS, i - 1, 0, {
        end_col = #row.text,
        hl_group = "VibingDiffHunk",
        line_hl_group = "VibingDiffHunk",
      })
    end
  end
end

---@param win number
---@param path string? 構文ハイライトを決めるためのファイルパス
---@param file_diff string?
---@param display string 出すものが無かった時に名乗る名前
---@return number buf
function M.render(win, path, file_diff, display)
  local rows = unified_lines.build(file_diff)
  if #rows == 0 then
    rows = { { text = "No changes for " .. display, kind = "info" } }
  end

  local text = {}
  for i, row in ipairs(rows) do
    text[i] = row.text
  end

  local Factory = require("vibing.infrastructure.ui.factory")
  local buf = Factory.create_buffer({ buftype = "nofile", bufhidden = "wipe", modifiable = true })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)

  -- 開くたびに引き直す。`ColorScheme` を監視しなくても今の配色に追従する
  highlights.define()
  M._decorate(buf, rows)

  local ft = path and vim.filetype.match({ filename = path })
  if ft then
    vim.bo[buf].filetype = ft
  end
  vim.bo[buf].modifiable = false

  vim.api.nvim_win_set_buf(win, buf)
  gutter.apply(win, buf, rows)

  return buf
end

---`diff.highlights = false` の時の描き方。patchのテキストをそのまま出し、色は
---カラースキームの `diff` 構文に任せる
---@param win number
---@param file_diff string?
---@param display string
---@return number buf
function M.render_plain(win, file_diff, display)
  gutter.reset(win)

  local Factory = require("vibing.infrastructure.ui.factory")
  local buf = Factory.create_buffer({
    buftype = "nofile",
    bufhidden = "wipe",
    filetype = "diff",
    modifiable = true,
  })

  local lines = { "No changes for " .. display }
  if file_diff and file_diff ~= "" then
    lines = vim.split(file_diff, "\n", { plain = true })
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_win_set_buf(win, buf)
  return buf
end

return M
