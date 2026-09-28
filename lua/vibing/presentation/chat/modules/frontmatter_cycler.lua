local Frontmatter = require("vibing.infrastructure.storage.frontmatter")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local Source = require("vibing.application.completion.sources.frontmatter")

---@class Vibing.Presentation.Chat.FrontmatterCycler
---frontmatterのenumフィールドの値をキー1つで巡回させる。
---
---候補は補完とまったく同じ経路（`Source.get_trigger_context` → `Source.get_candidates_sync`）
---から取る。enumの定義をここにもう1つ置くと、backendや`effort`の値が増えたときに補完だけが
---新しい値を知っている状態が黙って生まれる。補完は入力中の文字で候補を絞るが、巡回は全候補を
---回るので`query`を空にしてから渡す。
local M = {}

---@class Vibing.FrontmatterEnumAtCursor
---@field field string フィールド名
---@field value string 現在の値（未設定なら空文字）
---@field values string[] 候補（補完と同じ順序）

---指定行がfrontmatter領域内のenumフィールドなら、その内容と候補を返す
---
---領域の判定を省いて行の形だけを見ると、本文に書いた`model: x`のような行でも発火する。
---補完はカーソルが居る行しか見ないので済んでいるが、巡回はバッファを書き換える
---@param buf number
---@param lnum number 1-indexed
---@return Vibing.FrontmatterEnumAtCursor?
function M.enum_at(buf, lnum)
  local region = Frontmatter.buffer_region(buf)
  if not region or lnum <= 1 or lnum >= #region then
    return nil
  end

  local line = region[lnum]
  local ctx = Source.get_trigger_context(line, #line, buf)
  if not ctx or ctx.trigger ~= "frontmatter_enum" then
    return nil
  end

  local current = vim.trim(ctx.query)
  ctx.query = ""

  local values = {}
  for _, item in ipairs(Source.get_candidates_sync(ctx)) do
    table.insert(values, item.word)
  end
  if #values == 0 then
    return nil
  end

  return { field = ctx.field, value = current, values = values }
end

---@param values string[]
---@param current string
---@param direction number 1 | -1
---@return string
local function step(values, current, direction)
  for i, value in ipairs(values) do
    if value == current then
      return values[(i - 1 + direction) % #values + 1]
    end
  end
  -- 未設定も、候補から外れた値も、どちら向きに回しても候補の端に着地させる。
  -- 「いまの値の隣」が定義できない以上、端以外に選ぶ理由のある値がない
  return direction > 0 and values[1] or values[#values]
end

---行が動いても値を回し続けられるように、書き戻したフィールドの行までカーソルを運ぶ
---@param win number
---@param buf number
---@param field string
local function follow_field(win, buf, field)
  for i, line in ipairs(Frontmatter.buffer_region(buf) or {}) do
    if line:match("^" .. field .. ":") then
      vim.api.nvim_win_set_cursor(win, { i, 0 })
      return
    end
  end
end

---カーソル行のenumフィールドを次/前の値にする
---@param buf number
---@param direction number 1 | -1
---@return boolean cycled 巡回したか
function M.cycle(buf, direction)
  local win = vim.api.nvim_get_current_win()
  local found = M.enum_at(buf, vim.api.nvim_win_get_cursor(win)[1])
  if not found then
    return false
  end

  local next_value = step(found.values, found.value, direction)
  if next_value == found.value then
    return true
  end

  -- 行の切り貼りではなくparse→serializeで書き戻す（`frontmatter_handler`の#717）。
  -- `updated_at`は動かさない — 値を手で書き換えたときと同じ結果になるべきなので
  if not FrontmatterHandler.update_field(buf, found.field, next_value, false) then
    return false
  end

  follow_field(win, buf, found.field)
  return true
end

return M
