---@class Vibing.PatchViewer.DiffMode
---ペインを組み込みdiffモードに出し入れし、その見え方をフロートを開いている間だけ差し替える。
---
---`diffopt` は **グローバルオプション** なので、ここで書き換えると同時に開いている他の
---`:diffthis` にも効いてしまう。だから値を丸ごと預かって閉じる時に戻す。ユーザーの設定を
---捨てないよう、こちらが持つキーだけを置き換えて残りはそのまま引き継ぐ。
---
---`fillchars` は window-local なので、ペインに直接置けば外へ漏れない。
local M = {}

local highlights = require("vibing.ui.patch_viewer.highlights")

---差し替えるキー。古いNeovimが知らないものは 'E474' になるので1つずつ足す
---（`inline:char` は 0.11以降、`linematch` は 0.9以降）
local OVERRIDES = {
  "filler",
  "indent-heuristic",
  "algorithm:histogram",
  "linematch:60",
  "inline:char",
}

---@param entry string
---@return string
local function key_of(entry)
  return entry:match("^([^:]+)") or entry
end

---現在の `diffopt` から、こちらが持つキーを取り除いた残りを返す
---@param current string
---@return string[]
function M.keep(current)
  local overridden = {}
  for _, entry in ipairs(OVERRIDES) do
    overridden[key_of(entry)] = true
  end

  local kept = {}
  for _, entry in ipairs(vim.split(current, ",", { plain = true, trimempty = true })) do
    if not overridden[key_of(entry)] then
      table.insert(kept, entry)
    end
  end
  return kept
end

---@return string saved 復元用の元の値
function M.apply()
  local saved = vim.o.diffopt
  vim.o.diffopt = table.concat(M.keep(saved), ",")

  for _, entry in ipairs(OVERRIDES) do
    -- このNeovimが知らないキーは飛ばす。1つ弾かれても残りは効かせたい
    pcall(function()
      vim.opt.diffopt:append(entry)
    end)
  end

  return saved
end

---@param saved string?
function M.restore(saved)
  if saved then
    vim.o.diffopt = saved
  end
end

---今あるdiffペイン。unified では `win_before` が無いので、配列リテラルに nil を混ぜて
---`ipairs` で回すと先頭で止まる
---@param state Vibing.PatchViewer.State
---@return number[]
local function panes(state)
  local wins = {}
  if state.win_before and vim.api.nvim_win_is_valid(state.win_before) then
    table.insert(wins, state.win_before)
  end
  if state.win_after and vim.api.nvim_win_is_valid(state.win_after) then
    table.insert(wins, state.win_after)
  end
  return wins
end

---@param state Vibing.PatchViewer.State
function M.enter(state)
  if state.saved_diffopt == nil then
    state.saved_diffopt = M.apply()
  end

  local diff_config = ((require("vibing.config").options or {}).diff or {})
  local fill_char = diff_config.fill_char or "╱"
  local recolor = diff_config.highlights ~= false

  if recolor then
    -- 開くたびに引き直す。こうしておけば `ColorScheme` を監視しなくても今の配色に追従する
    highlights.define()
  end

  -- 割り当てが左右で違うので、どちらのペインかを持ったまま回す
  for _, pane in ipairs({ { state.win_before, "before" }, { state.win_after, "after" } }) do
    local win, side = pane[1], pane[2]
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd("diffthis")
      end)
      M.set_fill_char(win, fill_char)
      if recolor then
        highlights.apply(win, side)
      end
    end
  end
end

---@param state Vibing.PatchViewer.State
function M.leave(state)
  for _, win in ipairs(panes(state)) do
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffoff")
    end)
  end

  M.restore(state.saved_diffopt)
  state.saved_diffopt = nil
end

---削除行の穴埋め文字をペインに置く。既定の `-` は画面が横線で埋まって差分が読めない
---@param win number
---@param char string 空文字なら何もしない
function M.set_fill_char(win, char)
  if not char or char == "" then
    return
  end

  local entries = {}
  for _, item in ipairs(vim.split(vim.o.fillchars, ",", { plain = true, trimempty = true })) do
    if key_of(item) ~= "diff" then
      table.insert(entries, item)
    end
  end
  table.insert(entries, "diff:" .. char)

  -- 1文字でない値は 'E474'。ユーザー設定なので落とさず無視する
  pcall(function()
    vim.wo[win].fillchars = table.concat(entries, ",")
  end)
end

return M
