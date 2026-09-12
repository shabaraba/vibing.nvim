---@class Vibing.PatchViewer.Window
---Files / Before / After の3ペインをフロートで組む。
---
---Before は「ターン開始時の内容」を入れたスクラッチ、After は **実ファイルのバッファ**。
---両方を組み込みのdiffモードに入れるので、構文ハイライトも `do` / `dp` もそのまま効く。
---`diff` はウィンドウローカルなので、フロートを閉じれば実ファイル側に痕跡は残らない。
local M = {}

local Factory = require("vibing.infrastructure.ui.factory")

---@param state Vibing.PatchViewer.State
function M.create_layout(state)
  M.close_windows(state)

  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.8)
  local row = math.floor((vim.o.lines - total_height) / 2)
  local col = math.floor((vim.o.columns - total_width) / 2)
  local files_width = math.floor(total_width * 0.2)

  state.buf_files = Factory.create_buffer({ bufhidden = "wipe", modifiable = false })
  state.win_files = Factory.create_float({
    width = files_width,
    height = total_height,
    row = row,
    col = col,
    border = "rounded",
    title = "Files",
    enter = true,
  }, state.buf_files)

  -- unified は1枚の統一diffなので、Beforeペインを作らず残り幅をAfterが全部取る。
  -- `win_before` が nil のまま残る経路がここで生まれるので、以降のウィンドウ操作は
  -- `M._live` を通す（`ipairs` に nil を混ぜると先頭で止まる）
  if state.layout == "unified" then
    state.buf_after = Factory.create_buffer({ bufhidden = "wipe", modifiable = false })
    state.win_after = M._pane({
      width = total_width - files_width - 3,
      height = total_height,
      row = row,
      col = col + files_width + 3,
      title = "Diff",
    }, state.buf_after)
    return
  end

  -- 枠3つぶんの隙間（各2列）を引いてから左右に割る
  local pane_total = total_width - files_width - 6
  local before_width = math.floor(pane_total / 2)

  state.buf_before = Factory.create_buffer({ bufhidden = "wipe", modifiable = false })
  state.win_before = M._pane({
    width = before_width,
    height = total_height,
    row = row,
    col = col + files_width + 3,
    title = "Before (turn start)",
  }, state.buf_before)

  -- Afterは選択のたびに実ファイルのバッファへ差し替わる。最初のこれは器
  state.buf_after = Factory.create_buffer({ bufhidden = "wipe", modifiable = false })
  state.win_after = M._pane({
    width = pane_total - before_width,
    height = total_height,
    row = row,
    col = col + files_width + before_width + 6,
    title = "After (working tree)",
  }, state.buf_after)
end

---今あるウィンドウ（またはバッファ）だけを順に並べる。unified では `win_before` /
---`buf_before` が nil なので、素の配列リテラルでは `ipairs` が先頭で止まってしまう。
---可変引数で受けるのは、`{a, nil, c}` を `pairs` で回すと順番が保証されないため
---（`cycle_window` は並び順そのものが意味を持つ）
---@param ... number|nil
---@return number[]
function M._live(...)
  local live = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if value then
      table.insert(live, value)
    end
  end
  return live
end

---diffモードに入れるフロート
---
---`style = "minimal"` は 'number' / 'signcolumn' / 'foldcolumn' を落とすので、diffモードの
---折り畳みも行番号も見えなくなる。ここだけは通常ウィンドウと同じ描画にする。
---@param opts table
---@param buf number
---@return number winid
function M._pane(opts, buf)
  return Factory.create_float({
    width = opts.width,
    height = opts.height,
    row = opts.row,
    col = opts.col,
    border = "rounded",
    title = opts.title,
    enter = false,
    style = "none",
  }, buf)
end

---Afterペインのタイトルに、今出ているファイルのパスを出す。一覧はファイル名しか出せない幅なので
---フルパスの置き場はここしかない。長い時は頭を削って、ファイル名が消えないようにする
---@param state Vibing.PatchViewer.State
---@param path string?
function M.set_after_title(state, path)
  if not (state.win_after and vim.api.nvim_win_is_valid(state.win_after)) then
    return
  end

  local title = path or "After (working tree)"
  local room = vim.api.nvim_win_get_width(state.win_after) - 4
  if room > 1 and vim.fn.strwidth(title) > room then
    title = "…" .. vim.fn.strcharpart(title, vim.fn.strchars(title) - (room - 1))
  end

  pcall(vim.api.nvim_win_set_config, state.win_after, { title = " " .. title .. " ", title_pos = "center" })
end

---@param state Vibing.PatchViewer.State
function M.close_windows(state)
  for _, win in ipairs(M._live(state.win_files, state.win_before, state.win_after)) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs(M._live(state.buf_files, state.buf_before, state.buf_after)) do
    -- Afterペインに出ているのはユーザーの実ファイルのことがある。消してよいのは
    -- このビューアが作ったスクラッチだけ
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "nofile" then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state.win_files = nil
  state.win_before = nil
  state.win_after = nil
  state.buf_files = nil
  state.buf_before = nil
  state.buf_after = nil
end

---@param state Vibing.PatchViewer.State
---@param direction number
function M.cycle_window(state, direction)
  local wins = M._live(state.win_files, state.win_before, state.win_after)
  local current_win = vim.api.nvim_get_current_win()

  local current_idx = nil
  for i, win in ipairs(wins) do
    if win == current_win then
      current_idx = i
      break
    end
  end

  if not current_idx then
    if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      vim.api.nvim_set_current_win(wins[1])
    end
    return
  end

  local next_idx = current_idx + direction
  if next_idx > #wins then
    next_idx = 1
  elseif next_idx < 1 then
    next_idx = #wins
  end

  if wins[next_idx] and vim.api.nvim_win_is_valid(wins[next_idx]) then
    vim.api.nvim_set_current_win(wins[next_idx])
  end
end

return M
