---@class Vibing.Application.Chat.OrchestrationLink
---チャット同士のオーケストレーション関係を、双方の frontmatter に記録する。
---
---関係の唯一の記録がトランスクリプトの地の文だったのが元の状態で、それは二重に壊れる。
---bufnr は Neovim を再起動すれば別のバッファを指し、`:VibingSetFileTitle` はチャット
---ファイルを改名するので、書き残したパスは黙って腐る。`forked_from` が frontmatter +
---`ForkedChatScanner` で既に解いている問題なので、同じ形に揃える。
---
---方向を `orchestrated` / `orchestrated_by` の2フィールドに分けているのは、ワーカー側が
---「自分に指示を出したのは誰か」を答えられる必要があるため。隣のワーカーと区別のつかない
---フラットな集合では、そこに答えられない。
local M = {}

local Git = require("vibing.core.utils.git")
local FileManager = require("vibing.presentation.chat.modules.file_manager")

---@param bufnr number
---@return table? chat_buf
local function resolve_chat(bufnr)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  return require("vibing.presentation.chat.view").get_chat_buffer(bufnr)
end

---A が B に指示を出した関係を両者の frontmatter に書く
---
---呼び出しは `ProgrammaticSender.send` より**前**に済ませること。
---`update_frontmatter_list` はバッファを直接編集するので、B の応答が始まってから書くと
---ストリーミングと競合する。
---@param from_bufnr number 送信元（オーケストレーター側）
---@param to_bufnr number 送信先（ワーカー側）
---@return boolean success
---@return string? error
function M.link(from_bufnr, to_bufnr)
  if from_bufnr == to_bufnr then
    return false, "A chat cannot orchestrate itself"
  end

  local from_chat = resolve_chat(from_bufnr)
  local to_chat = resolve_chat(to_bufnr)
  if not from_chat or not to_chat then
    return false, "Both buffers must be vibing chat buffers"
  end

  local from_path = vim.api.nvim_buf_get_name(from_bufnr)
  local to_path = vim.api.nvim_buf_get_name(to_bufnr)
  if from_path == "" or to_path == "" then
    return false, "Both chats must have a file name"
  end

  from_chat:update_frontmatter_list("orchestrated", Git.to_display_path(to_path), "add")
  to_chat:update_frontmatter_list("orchestrated_by", Git.to_display_path(from_path), "add")

  -- `update_frontmatter_list` はバッファにしか書かない。リネーム同期はディスクを読むので、
  -- ここで保存しないとリンクは「次に何かの理由で保存されるまで」存在しないことになる。
  -- 送信元は `:VibingChat` の性質上まだ一度も保存されていないことがあり、その窓がいちばん
  -- 長い（＝1ターン目に投げた相手が改名されるとリンクが片方向に腐る）
  local saved_from = FileManager.save_buffer(from_bufnr)
  local saved_to = FileManager.save_buffer(to_bufnr)

  if not (saved_from and saved_to) then
    return false, "Wrote the orchestration link but could not save both chat files"
  end

  return true, nil
end

return M
