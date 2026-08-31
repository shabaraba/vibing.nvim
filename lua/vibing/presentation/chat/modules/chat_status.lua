---@class Vibing.Presentation.ChatStatus
---バッファ番号を、そのチャットが今どういう状態で止まっている（動いている）かに変換する
---
---オーケストレーター（`claude-plugin/skills/vibing-orchestrate`）がワーカーの進捗をポーリングするときの
---唯一の判定材料。本文から「最後のセクションがAssistantか」を推測する方法は、応答がエラーで
---終わった場合やツール実行だけで無言のまま進んでいる場合に誤判定するため使わない。
---
---「実行中か」と「なぜ止まったか」を1つの語彙に畳む presentation 側の合成であって、事実そのもの
---ではない。事実は `ChatBuffer:is_responding()` と `ChatBuffer:get_stop_reason()` が持っていて、
---`completion_notifier` の発火判定は後者を直接読む（この語彙を経由しない）。
local M = {}

---バッファのチャット実行状態を取得する
---
---`idle` は「リクエストが飛んでいない」だけを意味する。成功したかどうかは含まない —
---それを言えるのは、モデル自身がそう報告したときだけ。
---@param bufnr number バッファ番号（0はカレントバッファ）
---@return "responding"|"idle"|"waiting_approval"|"asked_question"|"error"|nil state vibing.nvimのチャットバッファでない場合はnil
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

  if chat_buf:is_responding() then
    return "responding"
  end

  -- 停止理由は「実行中でない」ときにしか意味を持たないので、`is_responding()` の後に読む
  return chat_buf:get_stop_reason() or "idle"
end

return M
