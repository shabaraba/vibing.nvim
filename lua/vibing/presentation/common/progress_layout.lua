---@class Vibing.Presentation.ProgressLayout
---進捗フロートの「置き方」。木の罫線、箱の幅、どこから何行見せるか、枠の設定。
---
---ウィンドウを持たず、値を受け取って値を返すだけなので、ここは窓を開けずに確かめられる。
---罫線の組み立ては添字の前後関係で決まるぶん間違えやすく、木が1段深いだけで見た目が崩れる。
---`progress.lua` に残るのは、その結果をウィンドウに貼る操作と生き死にだけ。
local M = {}

local Text = require("vibing.core.utils.text")

M.MIN_WIDTH = 28
M.MAX_WIDTH = 72
---ステータス列（記号＋空白）の幅。行頭の分だけ本文が狭くなる
M.GUTTER = 2
---スピナーのコマ送り。`progress.lua` のタイマー周期と同じでないと進みが飛ぶ
M.SPIN_MS = 120
---枠線ぶんを足した位置。ステータス行・コマンド行に被らないための余白
local BOTTOM_MARGIN = 4
local RIGHT_MARGIN = 3

local GLYPH = { pending = " ", ok = "✓", fail = "✗" }
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---先行順に並んだ深さの列から、各行の罫線を組む
---
---深さだけで組めるのは、子が親のすぐ下に来ている（先行順である）ことが前提。ある段に続きが
---あるかどうかは、自分より浅い深さが現れるまでの間に同じ深さがもう一度出てくるかで決まる。
---「次の行の深さ」で判定すると、孫を挟んだ兄弟のところで罫線が切れる
---@param items Vibing.Progress.Item[]
---@return string[]
function M.prefixes(items)
  -- 木にせず並べるだけの使い方に `depth = 0` を毎要素書かせない
  local function depth_of(index)
    return items[index].depth or 0
  end

  ---@param index integer
  ---@param depth integer
  ---@return boolean その段にまだ兄弟が残っているか
  local function has_sibling_below(index, depth)
    for j = index + 1, #items do
      if depth_of(j) < depth then
        return false
      end
      if depth_of(j) == depth then
        return true
      end
    end
    return false
  end

  local prefixes = {}
  for i = 1, #items do
    local parts = {}
    for d = 1, depth_of(i) - 1 do
      table.insert(parts, has_sibling_below(i, d) and "│  " or "   ")
    end
    if depth_of(i) > 0 then
      table.insert(parts, has_sibling_below(i, depth_of(i)) and "├─ " or "└─ ")
    end
    prefixes[i] = table.concat(parts)
  end
  return prefixes
end

---箱の幅を決める。中身に合わせたうえで [MIN_WIDTH, MAX_WIDTH] に収め、狭い画面では
---画面幅を超えないほうを優先する（超えると `nvim_open_win` が失敗する）
---@param items Vibing.Progress.Item[]
---@param prefixes string[]
---@return integer
function M.width(items, prefixes)
  local longest = 0
  for i, item in ipairs(items) do
    longest = math.max(longest, vim.fn.strdisplaywidth(prefixes[i] .. item.label) + M.GUTTER)
  end
  local width = math.min(M.MAX_WIDTH, math.max(M.MIN_WIDTH, longest))
  return M.fit_width(width)
end

---画面幅を超えないところまで詰める（超えると `nvim_open_win` が失敗する）
---@param width integer
---@return integer
function M.fit_width(width)
  return math.max(math.min(width, vim.o.columns - 4), 1)
end

---一度に見せる行数。0件でも1を返す — `nvim_open_win` は `height = 0` を受け付けない。
---呼び出し側が0件を弾いている保証はここには無い
---@param count integer 総件数
---@return integer
function M.height(count)
  return math.max(math.min(count, math.max(3, math.floor(vim.o.lines * 0.4))), 1)
end

---木の全体が入らないときに、いま動いている行が見えるところまで送る
---@param count integer 総件数
---@param height integer 一度に見せる行数
---@param running integer? 動いている行
---@return integer first 先頭に出す添字
function M.first_visible(count, height, running)
  if count <= height then
    return 1
  end
  local first = (running or count) - math.floor(height / 2)
  return math.min(math.max(first, 1), count - height + 1)
end

---バッファに書く行をまとめて組む
---@param opts {items: Vibing.Progress.Item[], prefixes: string[], status: table, running: integer?, height: integer, width: integer, message: string?}
---@return string[]
function M.lines(opts)
  local first = M.first_visible(#opts.items, opts.height, opts.running)
  local lines = {}

  for i = first, math.min(first + opts.height - 1, #opts.items) do
    local glyph = GLYPH[opts.status[i] or "pending"]
    if i == opts.running then
      -- コマの進みは時計から引く。自前のカウンタを持つと、それを進めるためだけに
      -- タイマーのコールバックが存在することになる
      glyph = SPINNER[math.floor(vim.uv.now() / M.SPIN_MS) % #SPINNER + 1]
    end
    table.insert(lines, glyph .. " " .. Text.head(opts.prefixes[i] .. opts.items[i].label, opts.width - M.GUTTER))
  end

  if opts.message then
    table.insert(lines, Text.head(opts.message, opts.width))
  end
  return lines
end

---フロートのウィンドウ設定。件数を枠のタイトルに出すので、行が流れても総数は見えたまま
---@param opts {width: integer, rows: integer, title: string, settled: integer, total: integer}
---@return table
function M.window(opts)
  return {
    relative = "editor",
    width = opts.width,
    height = opts.rows,
    row = math.max(vim.o.lines - opts.rows - BOTTOM_MARGIN, 0),
    col = math.max(vim.o.columns - opts.width - RIGHT_MARGIN, 0),
    style = "minimal",
    border = "rounded",
    title = string.format(" %s %d/%d ", opts.title, opts.settled, opts.total),
    title_pos = "left",
    zindex = 60,
  }
end

return M
