---@class Vibing.Application.Chat.Search.ChatDirectory
---`:VibingChatSearch` の検索先。`chat.storage.location` がプロジェクト（既定）なら
---`vibing-chat-search` スキルの Step 1 と同じ順で、git ルートの `.vibing/chat/`、無ければ
---カレントディレクトリの `.vibing/chat/` を探す。`user` / `custom` ならチャットの保存先そのもの。
local M = {}

local Git = require("vibing.core.utils.git")

---@param storage table? `chat.storage`
---@param cwd string
---@return string[]
local function candidates(storage, cwd)
  local location = storage and storage.location or "project"
  if location == "user" then
    return { vim.fn.stdpath("data") .. "/vibing/chats" }
  elseif location == "custom" then
    return { ((storage.path or vim.fn.stdpath("data") .. "/vibing/chats"):gsub("/+$", "")) }
  end

  local list = {}
  local root = Git.get_root(cwd)
  if root and root ~= "" then
    list[#list + 1] = root .. "/.vibing/chat"
  end
  list[#list + 1] = cwd .. "/.vibing/chat"
  return list
end

---@param storage table? `chat.storage`。省略時はプロジェクト
---@param cwd string? 省略時は Neovim のカレントディレクトリ
---@return string? directory 存在する検索先。無ければ nil
function M.resolve(storage, cwd)
  cwd = (cwd or vim.fn.getcwd()):gsub("/+$", "")
  for _, dir in ipairs(candidates(storage, cwd)) do
    dir = vim.fn.fnamemodify(dir, ":p"):gsub("/$", "")
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil
end

return M
