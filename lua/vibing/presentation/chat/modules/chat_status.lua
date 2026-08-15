---@class Vibing.Presentation.ChatStatus
---バッファ番号を、そのチャットが今リクエストを実行中かどうかに変換する
---
---オーケストレーター（`claude-plugin/skills/vibing-orchestrate`）がワーカーの進捗をポーリングするときの
---唯一の判定材料。本文から「最後のセクションがAssistantか」を推測する方法は、応答がエラーで
---終わった場合やツール実行だけで無言のまま進んでいる場合に誤判定するため使わない。
local M = {}

---バッファのチャット実行状態を取得する
---@param bufnr number バッファ番号（0はカレントバッファ）
---@return "responding"|"idle"|nil state vibing.nvimのチャットバッファでない場合はnil
function M.get(bufnr)
  if not bufnr or bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local chat_buf = require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
  if not chat_buf then
    return nil
  end

  return chat_buf:is_responding() and "responding" or "idle"
end

return M
