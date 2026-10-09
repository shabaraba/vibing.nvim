---@class Vibing.Application.Chat.Search.ChatAnswer
---`:VibingChatSearch` のエージェントの答え（末尾の JSON）を、開けるチャットの一覧に読み替える。
local M = {}

local FileEntity = require("vibing.domain.chat.file_entity")
local FileBuffer = require("vibing.core.utils.file_buffer")
local BackgroundAgent = require("vibing.application.chat.search.background_agent")

---@class Vibing.Chat.Search.Result
---@field entity Vibing.Domain.Chat.FileEntity
---@field summary string
---@field group string 検索語との関係で分けた分類名

---相対パスは、ツールが報告する形（エージェントの cwd 基準）を先に、検索したディレクトリ基準を
---次に試す。どちらで引いても、そのディレクトリから外れたファイルは結果にしない
---@param path string
---@param chat_dir string
---@param cwd string
---@return string?
local function resolve_path(path, chat_dir, cwd)
  local root = FileBuffer.canonical(chat_dir):gsub("/$", "")
  if root == "" then
    return nil
  end

  local candidates = path:sub(1, 1) == "/" and { path } or { cwd .. "/" .. path, chat_dir .. "/" .. path }
  for _, candidate in ipairs(candidates) do
    local canonical = FileBuffer.canonical(candidate)
    if vim.startswith(canonical, root .. "/") and vim.fn.filereadable(canonical) == 1 then
      return canonical
    end
  end
  return nil
end

---@param value any
---@return string
local function one_line(value)
  return type(value) == "string" and (vim.trim(value):gsub("%s*\n%s*", " ")) or ""
end

---@param text string?
---@param chat_dir string
---@param cwd string エージェントを走らせたディレクトリ
---@return Vibing.Chat.Search.Result[]? results
---@return string? error
function M.parse(text, chat_dir, cwd)
  local decoded, err = BackgroundAgent.last_json(text)
  if not decoded then
    return nil, err
  end
  if type(decoded.groups) ~= "table" then
    return nil, "the search agent returned a malformed result"
  end

  local results = {}
  local seen = {}

  for _, group in ipairs(decoded.groups) do
    local label = type(group) == "table" and one_line(group.label) or ""
    local chats = type(group) == "table" and type(group.chats) == "table" and group.chats or {}

    for _, chat in ipairs(chats) do
      local path = type(chat) == "table" and type(chat.path) == "string" and resolve_path(chat.path, chat_dir, cwd)
      local entity = path and not seen[path] and FileEntity.new(path)
      if entity then
        seen[path] = true
        results[#results + 1] = { entity = entity, summary = one_line(chat.summary), group = label }
      end
    end
  end

  return results, nil
end

return M
