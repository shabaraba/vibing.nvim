---@class Vibing.Infrastructure.PatchStorage
local M = {}

local VALID_SESSION_ID_PATTERN = "^[%w%-_]+$"
local VALID_PATCH_FILENAME_PATTERN = "^[%d%-TZ]+%.patch$"

---@param session_id string
---@return boolean
local function is_valid_session_id(session_id)
  return session_id and session_id ~= "" and session_id:match(VALID_SESSION_ID_PATTERN) ~= nil
end

---@param filename string
---@return boolean
local function is_valid_patch_filename(filename)
  return filename and filename ~= "" and filename:match(VALID_PATCH_FILENAME_PATTERN) ~= nil
end

---@return string
local function get_patches_base_dir()
  local config = require("vibing").get_config()
  local location_type = config.chat.save_location_type or "project"

  if location_type == "user" then
    return vim.fn.stdpath("data") .. "/vibing/patches"
  elseif location_type == "custom" then
    local base_path = (config.chat.save_dir or vim.fn.getcwd() .. "/.vibing"):gsub("/chats?/?$", "")
    return base_path .. "/patches"
  end

  return vim.fn.getcwd() .. "/.vibing/patches"
end

---@param session_id string
---@return string
local function get_patch_dir(session_id)
  return get_patches_base_dir() .. "/" .. session_id
end

---@param session_id string
---@param patch_filename string
---@return string?
function M.read(session_id, patch_filename)
  if not is_valid_session_id(session_id) or not is_valid_patch_filename(patch_filename) then
    return nil
  end

  local patch_path = get_patch_dir(session_id) .. "/" .. patch_filename
  if vim.fn.filereadable(patch_path) ~= 1 then
    return nil
  end

  return table.concat(vim.fn.readfile(patch_path), "\n")
end

---@param session_id string
---@param patch_filename string
---@return boolean
function M.revert(session_id, patch_filename)
  if not is_valid_session_id(session_id) or not is_valid_patch_filename(patch_filename) then
    return false
  end

  local patch_path = get_patch_dir(session_id) .. "/" .. patch_filename
  if vim.fn.filereadable(patch_path) ~= 1 then
    return false
  end

  local cmd = string.format("git apply -R %s", vim.fn.shellescape(patch_path))
  local result = vim.fn.system({ "sh", "-c", cmd })

  if vim.v.shell_error ~= 0 then
    vim.schedule(function()
      vim.notify("git apply -R failed: " .. vim.trim(result or ""), vim.log.levels.DEBUG)
    end)
    return false
  end

  return true
end

---@param session_id string
---@return boolean
function M.delete_session(session_id)
  if not is_valid_session_id(session_id) then
    return false
  end

  local patch_dir = get_patch_dir(session_id)
  if vim.fn.isdirectory(patch_dir) ~= 1 then
    return true
  end

  vim.fn.delete(patch_dir, "rf")
  return vim.fn.isdirectory(patch_dir) ~= 1
end

---@param session_id string
---@return string[]
function M.list(session_id)
  if not is_valid_session_id(session_id) then
    return {}
  end

  local patch_dir = get_patch_dir(session_id)
  if vim.fn.isdirectory(patch_dir) ~= 1 then
    return {}
  end

  local files = vim.fn.glob(patch_dir .. "/*.patch", false, true)
  local result = vim.tbl_map(function(f) return vim.fn.fnamemodify(f, ":t") end, files)
  table.sort(result)

  return result
end

---@param session_id string
---@param patch_filename string
---@return boolean
function M.exists(session_id, patch_filename)
  if not session_id or not patch_filename then
    return false
  end

  return vim.fn.filereadable(get_patch_dir(session_id) .. "/" .. patch_filename) == 1
end

return M
