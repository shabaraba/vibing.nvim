---@class Vibing.Core.Utils.Text
---表示幅で切り詰める。`strcharpart` は文字数で数えるので、CJKなど幅2の文字が混じると
---切った結果が枠に収まらず、末尾から残す側では開始位置が負になって「末尾から数える」
---Vimの挙動に化ける。
---
---枠に文字を収める必要のあるUIは patch viewer だけではないので（進捗フロートもここを使う）、
---`ui/patch_viewer/` ではなく共有の置き場に居る。2つ目の実装を書かないこと。
local M = {}

---@param text string
---@param budget number 残してよい表示幅
---@param keep "head"|"tail"
---@return string
local function clip(text, budget, keep)
  local chars = vim.fn.split(text, "\\zs")
  local kept, width = {}, 0
  local first, last, step = 1, #chars, 1
  if keep == "tail" then
    first, last, step = #chars, 1, -1
  end
  for i = first, last, step do
    width = width + vim.fn.strwidth(chars[i])
    if width > budget then
      break
    end
    table.insert(kept, keep == "tail" and 1 or #kept + 1, chars[i])
  end
  return table.concat(kept)
end

---先頭を残して末尾を省く（`abcdef` → `abc…`）
---@param text string
---@param width number 省略記号を含めて収めたい表示幅
---@return string
function M.head(text, width)
  if vim.fn.strwidth(text) <= width then
    return text
  end
  return clip(text, math.max(0, width - 1), "head") .. "…"
end

---末尾を残して先頭を省く（`abcdef` → `…def`）。パスはファイル名側が残ってほしい
---@param text string
---@param width number 省略記号を含めて収めたい表示幅
---@return string
function M.tail(text, width)
  if vim.fn.strwidth(text) <= width then
    return text
  end
  return "…" .. clip(text, math.max(0, width - 1), "tail")
end

return M
