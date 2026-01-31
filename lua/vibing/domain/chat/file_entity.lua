---@class Vibing.Domain.Chat.FileEntity
---@field path string
---@field basename string
---@field display_name string
---@field is_renamed boolean
---@field created_at number|nil
---@field size number|nil
---@field _formatted_date string
---@field _formatted_size string
local FileEntity = {}
FileEntity.__index = FileEntity

---@class Vibing.Domain.Chat.FileEntityData
---@field path string
---@field basename string
---@field display_name string
---@field is_renamed boolean
---@field created_at number|nil
---@field size number|nil

---@param path string
---@return Vibing.Domain.Chat.FileEntity?
function FileEntity.new(path)
  if not path or path == "" then
    return nil
  end

  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end

  local self = setmetatable({}, FileEntity)
  self.path = vim.fn.fnamemodify(path, ":p")
  self.basename = vim.fn.fnamemodify(path, ":t")
  self.display_name = vim.fn.fnamemodify(path, ":t:r")

  local stat = vim.loop.fs_stat(path)
  if stat then
    self.created_at = stat.mtime.sec
    self.size = stat.size
  end

  self.is_renamed = not self:_is_default_filename()
  self._formatted_date = self:_format_date()
  self._formatted_size = self:_format_size()

  return self
end

---@return boolean
function FileEntity:_is_default_filename()
  return self.basename:match("^chat%-%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-.+%.vibing$") ~= nil
end

---@return string
function FileEntity:get_display_name()
  return self.display_name
end

---@return string
function FileEntity:get_relative_path()
  local Git = require("vibing.core.utils.git")
  return Git.to_display_path(self.path)
end

---@return string
function FileEntity:_format_date()
  if not self.created_at then
    return "Unknown"
  end
  return os.date("%Y-%m-%d %H:%M:%S", self.created_at)
end

---@return string
function FileEntity:_format_size()
  if not self.size then
    return "0 B"
  end

  local size = self.size
  local units = { "B", "KB", "MB", "GB" }
  local unit_index = 1

  while size >= 1024 and unit_index < #units do
    size = size / 1024
    unit_index = unit_index + 1
  end

  return string.format("%.1f %s", size, units[unit_index])
end

---@return string
function FileEntity:get_formatted_date()
  return self._formatted_date
end

---@return string
function FileEntity:get_formatted_size()
  return self._formatted_size
end

---@return boolean
function FileEntity:is_renamed_file()
  return self.is_renamed
end

---@return Vibing.Domain.Chat.FileEntityData
function FileEntity:to_table()
  return {
    path = self.path,
    basename = self.basename,
    display_name = self.display_name,
    is_renamed = self.is_renamed,
    created_at = self.created_at,
    size = self.size,
  }
end

return FileEntity
