---@class Vibing.Infrastructure.FileReader
---ファイル読み込みのインフラ層
local M = {}

---ファイルを読み込む
---@param path string
---@return string? content
---@return string? error
function M.read(path)
  local file, err = io.open(path, "r")
  if not file then
    return nil, err
  end
  local content = file:read("*a")
  file:close()
  return content, nil
end

---ファイルを行単位で読み込む
---@param path string
---@return string[]? lines
---@return string? error
function M.read_lines(path)
  local content, err = M.read(path)
  if not content then
    return nil, err
  end
  return vim.split(content, "\n", { plain = true }), nil
end

---ファイルが存在するか確認
---@param path string
---@return boolean
function M.exists(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil
end

---ファイルが読み込み可能か確認
---@param path string
---@return boolean
function M.is_readable(path)
  local file = io.open(path, "r")
  if file then
    file:close()
    return true
  end
  return false
end

---ディレクトリが存在するか確認
---@param path string
---@return boolean
function M.is_directory(path)
  local stat = vim.loop.fs_stat(path)
  return stat ~= nil and stat.type == "directory"
end

return M
