-- lua/vibing/infrastructure/workspace/meta.lua
---@class Vibing.Infrastructure.Workspace.Meta
---meta.yaml の読み書き。既存の Frontmatter パーサをそのまま再利用する
---（--- ... --- で囲むことで、実装済みのYAMLサブセットパーサをそのまま使い回せるため）
local M = {}

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@param meta_path string
---@param data table
---@return boolean success
function M.write(meta_path, data)
  local content = Frontmatter.serialize(data, "")
  return vim.fn.writefile(vim.split(content, "\n"), meta_path) == 0
end

---@param meta_path string
---@return table? data
function M.read(meta_path)
  if vim.fn.filereadable(meta_path) == 0 then
    return nil
  end
  local content = table.concat(vim.fn.readfile(meta_path), "\n")
  local data = Frontmatter.parse(content)
  return data
end

---@param meta_path string
---@param chat_file string
---@return boolean success
---@return string? error
function M.add_chat_file(meta_path, chat_file)
  local data = M.read(meta_path)
  if not data then
    return false, "meta.yaml not found: " .. meta_path
  end

  data.chat_files = data.chat_files or {}
  for _, existing in ipairs(data.chat_files) do
    if existing == chat_file then
      return true
    end
  end

  table.insert(data.chat_files, chat_file)
  return M.write(meta_path, data)
end

---@param meta_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function M.replace_chat_file(meta_path, old_path, new_path)
  local data = M.read(meta_path)
  if not data or not data.chat_files then
    return false, "no chat_files in meta.yaml: " .. meta_path
  end

  local found = false
  for i, existing in ipairs(data.chat_files) do
    if existing == old_path then
      data.chat_files[i] = new_path
      found = true
    end
  end

  if not found then
    return false, "chat_file not found: " .. old_path
  end

  return M.write(meta_path, data)
end

return M
