---@class Vibing.Infrastructure.Link.Scanner
local Scanner = {}
Scanner.__index = Scanner

---@param base_dir string
---@return string[]
function Scanner:find_target_files(base_dir)
  error("Must be implemented by subclass")
end

---@param file_path string
---@param target_path string
---@return boolean
function Scanner:contains_link(file_path, target_path)
  error("Must be implemented by subclass")
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function Scanner:update_link(file_path, old_path, new_path)
  error("Must be implemented by subclass")
end

return Scanner
