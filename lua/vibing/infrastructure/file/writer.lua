---@class Vibing.Infrastructure.FileWriter
---ファイル書き込みのインフラ層
local M = {}

---ファイルに書き込む
---@param path string
---@param content string
---@return boolean success
---@return string? error
function M.write(path, content)
  local file, err = io.open(path, "w")
  if not file then
    return false, err
  end
  file:write(content)
  file:close()
  return true, nil
end

---ファイルに追記
---@param path string
---@param content string
---@return boolean success
---@return string? error
function M.append(path, content)
  local file, err = io.open(path, "a")
  if not file then
    return false, err
  end
  file:write(content)
  file:close()
  return true, nil
end

---ディレクトリを作成
---@param path string
---@return boolean success
function M.mkdir(path)
  return vim.fn.mkdir(path, "p") == 1
end

---ファイルを削除
---@param path string
---@return boolean success
function M.remove(path)
  local ok, err = os.remove(path)
  return ok ~= nil
end

---ファイルをコピー
---@param src string
---@param dest string
---@return boolean success
---@return string? error
function M.copy(src, dest)
  local content, err = require("vibing.infrastructure.file.reader").read(src)
  if not content then
    return false, err
  end
  return M.write(dest, content)
end

return M
