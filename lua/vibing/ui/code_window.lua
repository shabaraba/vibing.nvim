---@class Vibing.UI.CodeWindow
---「チャットを潰さずに実ファイルを開く」を一箇所に置いたもの。
---
---`gd` のインライン表示も、patch_viewerの「このファイルを開く」も、同じ問題を持つ:
---呼ばれるのはチャットウィンドウ（かフロート）の中で、そこに `:edit` すると呼び出し元ごと
---消える。どちらも同じ選び方をする必要があるので、実装は1つ。
local M = {}

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---ファイルを開いてよい通常ウィンドウを選ぶ。無ければ縦分割で作る
---@return number winnr
function M.pick()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      -- フロートは閉じられる前提の一時ウィンドウなので、そこにファイルを開くと差分ごと消える。
      -- `buftype ~= ""` はターミナル・quickfix・help・ファイラ（oil等）で、どれも `:edit` で
      -- 乗っ取ってよいウィンドウではない。この2つを外すと、残るのは普通のファイル用ウィンドウ
      local is_float = vim.api.nvim_win_get_config(win).relative ~= ""
      local is_normal = vim.bo[buf].buftype == ""
      if not is_float and is_normal and not Frontmatter.is_vibing_chat_buffer(buf) then
        return win
      end
    end
  end

  vim.cmd("vsplit")
  return vim.api.nvim_get_current_win()
end

---選んだウィンドウに対象ファイルを出し、そこへフォーカスを移す
---@param file_path string
---@return number|nil buf 開けなければnil
function M.open_file(file_path)
  local win = M.pick()
  vim.api.nvim_set_current_win(win)

  local abs = vim.fn.fnamemodify(file_path, ":p")
  -- 既にそのファイルが出ているなら `:edit` しない。素のリロードはmini.diffのバッファ
  -- watcherをdetachさせ、カーソル位置もundo履歴も捨てる
  if vim.api.nvim_buf_get_name(0) == abs then
    return vim.api.nvim_get_current_buf()
  end

  -- 選ばれたウィンドウのバッファが未保存だと素の `:edit` はE37で落ちる。呼び出し元は
  -- pcallしないので、ここで受け止めてフォールバックに繋げる
  if not pcall(vim.cmd.edit, vim.fn.fnameescape(abs)) then
    return nil
  end
  return vim.api.nvim_get_current_buf()
end

return M
