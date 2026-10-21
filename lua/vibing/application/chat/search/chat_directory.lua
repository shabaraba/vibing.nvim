---@class Vibing.Application.Chat.Search.ChatDirectory
---`:VibingChatSearch` の検索先。`vibing-chat-search` スキルの Step 1 と同じ順で探す:
---git ルートの `.vibing/chat/`、無ければカレントディレクトリの `.vibing/chat/`。
local M = {}

local Git = require("vibing.core.utils.git")

---@param cwd string
---@return string[]
local function candidates(cwd)
  local list = {}
  local root = Git.get_root(cwd)
  if root and root ~= "" then
    list[#list + 1] = root .. "/.vibing/chat"
  end
  list[#list + 1] = cwd .. "/.vibing/chat"
  return list
end

---@param cwd string? 省略時は Neovim のカレントディレクトリ
---@return string? directory 存在する検索先。どちらも無ければ nil
function M.resolve(cwd)
  cwd = (cwd or vim.fn.getcwd()):gsub("/+$", "")
  for _, dir in ipairs(candidates(cwd)) do
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return nil
end

return M
