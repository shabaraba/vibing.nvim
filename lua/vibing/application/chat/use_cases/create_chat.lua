---@class Vibing.Application.CreateChatUseCase
---プログラムからの新規チャット作成（MCPツール `nvim_chat_create` の実体）
---
---`:VibingChat` と違うのは `working_dir` を指定できる点だけで、セッション生成そのものは
---`use_case.create_new` に委譲する。fork/subagent_chat と同じく、ここはPresentation層に
---依存しない: 呼び出し元が返ってきたsessionをviewに渡す
local M = {}

local Git = require("vibing.core.utils.git")

---新しいチャットセッションを作成する
---@param opts? {working_dir?: string} working_dirはgitルートからの相対パス
---@return Vibing.ChatSession
---@throws working_dirがgit管理外、または存在しないディレクトリを指している場合
function M.execute(opts)
  opts = opts or {}
  local working_dir = opts.working_dir

  if not working_dir or working_dir == "" then
    return require("vibing.application.chat.use_case").create_new()
  end

  -- 存在しないディレクトリを受け入れると、チャットは作れてしまうのに最初のリクエストで
  -- 初めて失敗する。しかもワーカーのバッファはユーザーが見ていないので、ここで弾く
  local absolute = Git.resolve_working_dir(working_dir)
  if not absolute then
    error("Cannot resolve working_dir '" .. working_dir .. "': not inside a git repository")
  end
  if vim.fn.isdirectory(absolute) ~= 1 then
    error("working_dir does not exist: " .. working_dir .. " (resolved to " .. absolute .. ")")
  end

  return require("vibing.application.chat.use_case").create_new({ working_dir = working_dir })
end

return M
