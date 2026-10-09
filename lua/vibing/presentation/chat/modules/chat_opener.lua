---@class Vibing.Presentation.Chat.ChatOpener
---選ばれたチャットファイル群を開く。
---
---表示するのは先頭の1つだけで、残りはバッファに読み込むだけにする。`:bnext` で回ったときに
---ただの Markdown ではなくチャットとして振る舞うよう、見せないほうも `view.attach_to_buffer`
---を通す（キーマップとバッファ設定はそこで付く）。
---
---そのファイルのバッファが既にあるときの扱いは `view.render` の仕事で、ここは何も判定しない
---（判定が2箇所あれば、片方だけ直したときに E95 が戻ってくる）。
local M = {}

---@param path string
local function load_in_background(path)
  local bufnr = vim.fn.bufadd(path)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  require("vibing.presentation.chat.view").attach_to_buffer(bufnr, path)
end

---@param path string
---@return boolean displayed
local function display(path)
  local session = require("vibing.application.chat.use_case").open_file(path)
  if not session then
    require("vibing.core.utils.notify").error("Failed to load: " .. path, "Chat")
    return false
  end

  require("vibing.presentation.chat.view").render(session)
  return true
end

---@param paths string[]
---@return integer opened 開けた件数
function M.open_all(paths)
  local opened = 0

  for _, path in ipairs(paths or {}) do
    if opened > 0 then
      load_in_background(path)
      opened = opened + 1
    elseif display(path) then
      opened = opened + 1
    end
  end

  return opened
end

return M
