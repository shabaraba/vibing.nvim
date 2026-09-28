---@class Vibing.Core.Utils.Text
---表示幅で切り詰める・折り返す。`strcharpart` は文字数で数えるので、CJKなど幅2の文字が混じると
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

---@param ch string
---@return boolean 折り返し位置として単語の途中とみなす文字か（ASCIIの非空白だけ）
local function in_word(ch)
  return ch ~= nil and #ch == 1 and ch:match("%s") == nil
end

---表示幅で折り返す。英文は直前の空白まで戻して単語を割らず、空白のないCJKや
---幅に収まらない1語は文字単位で折る。改行は含まない1行を渡すこと。
---@param text string
---@param width number 1行に収めたい表示幅
---@return string[] 1行以上。空文字列には空文字列1つを返す
function M.wrap(text, width)
  width = math.max(1, math.floor(width))
  local chars = vim.fn.split(text, "\\zs")
  local lines, current, current_width = {}, {}, 0

  for _, ch in ipairs(chars) do
    local w = vim.fn.strwidth(ch)
    if current_width + w > width and #current > 0 then
      -- 単語の途中で切ろうとしているときだけ、直前の空白まで戻して持ち越す
      local space_at
      if in_word(ch) and in_word(current[#current]) then
        for i = #current - 1, 1, -1 do
          if current[i]:match("%s") then
            space_at = i
            break
          end
        end
      end

      local carry = {}
      if space_at then
        for i = space_at + 1, #current do
          table.insert(carry, current[i])
        end
        for i = #current, space_at, -1 do
          table.remove(current, i)
        end
      end

      -- 折り返し位置の空白は行末に残さない。次行の行頭でも同じ理由で落としている
      table.insert(lines, (table.concat(current):gsub("%s+$", "")))
      current, current_width = carry, 0
      for _, c in ipairs(carry) do
        current_width = current_width + vim.fn.strwidth(c)
      end
    end

    -- 折り返した直後の行頭に空白を残すと、字下げされたように見えてしまう
    if not (#current == 0 and #lines > 0 and ch:match("%s")) then
      table.insert(current, ch)
      current_width = current_width + w
    end
  end

  table.insert(lines, table.concat(current))
  return lines
end

return M
