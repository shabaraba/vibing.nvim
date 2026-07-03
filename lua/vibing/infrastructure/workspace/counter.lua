-- lua/vibing/infrastructure/workspace/counter.lua
---@class Vibing.Infrastructure.Workspace.Counter
---.vibing/workspace/.counter を使ったグローバル連番採番
local M = {}

local Git = require("vibing.core.utils.git")

---@return string?
function M.get_counter_path()
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end
  return git_root .. "/.vibing/workspace/.counter"
end

---次の連番を採番し、カウンタファイルに永続化する
---@return number? next_number
---@return string? error
function M.next()
  local path = M.get_counter_path()
  if not path then
    return nil, "Not in a git repository"
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local current = 0
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    current = tonumber(lines[1]) or 0
  end

  local next_number = current + 1
  local result = vim.fn.writefile({ tostring(next_number) }, path)
  if result ~= 0 then
    return nil, "Failed to write counter file: " .. path
  end

  return next_number
end

return M
