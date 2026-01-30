---@class Vibing.PatchViewer.Revert
local M = {}

local parser = require("vibing.ui.patch_viewer.parser")

---@param context_dir string
---@param snapshot_id string
---@param file string
---@return boolean success
---@return string? error_message
local function restore_file(context_dir, snapshot_id, file)
  local Binary = require("vibing.core.utils.mote.binary")
  local mote_bin = Binary.get_path()

  local cmd = string.format(
    "%s -d %s snap restore -f %s %s",
    vim.fn.shellescape(mote_bin),
    vim.fn.shellescape(context_dir),
    vim.fn.shellescape(file),
    vim.fn.shellescape(snapshot_id)
  )

  local result = vim.fn.system({ "sh", "-c", cmd })
  if vim.v.shell_error ~= 0 then
    return false, vim.trim(result or "")
  end
  return true, nil
end

---@param patch_filename string
---@return string? snapshot_id
---@return string? context_dir
---@return string? error
local function prepare_revert(patch_filename)
  local patch_path = parser.resolve_patch_path(patch_filename)
  if not patch_path then
    return nil, nil, "Patch file not found: " .. patch_filename
  end

  local patch_content = parser.read_patch_file(patch_path)
  if not patch_content then
    return nil, nil, "Failed to read patch file: " .. patch_filename
  end

  local snapshot_id = parser.extract_snapshot_id(patch_content)
  if not snapshot_id then
    return nil, nil, "Failed to extract snapshot ID from patch"
  end

  local context_dir = parser.extract_context_dir(patch_path)
  if not context_dir then
    return nil, nil, "Failed to extract context directory from patch path"
  end

  local Binary = require("vibing.core.utils.mote.binary")
  if not Binary.is_available() then
    return nil, nil, "mote binary not found. Cannot revert patch."
  end

  return snapshot_id, context_dir, nil
end

---@param _ string
---@param patch_filename string
---@param selected_file string
---@return boolean
function M.revert_single_file(_, patch_filename, selected_file)
  local snapshot_id, context_dir, err = prepare_revert(patch_filename)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  local success, error_msg = restore_file(context_dir, snapshot_id, selected_file)
  if not success then
    vim.notify(
      string.format("Failed to revert %s:\n%s", selected_file, error_msg or ""),
      vim.log.levels.ERROR
    )
    return false
  end

  local BufferReload = require("vibing.core.utils.buffer_reload")
  BufferReload.reload_files({ selected_file })

  vim.notify(string.format("Reverted %s to snapshot %s", selected_file, snapshot_id), vim.log.levels.INFO)
  return true
end

---@param _ string
---@param patch_filename string
---@return boolean
function M.revert_all_files(_, patch_filename)
  local snapshot_id, context_dir, err = prepare_revert(patch_filename)
  if err then
    vim.notify(err, vim.log.levels.ERROR)
    return false
  end

  local patch_path = parser.resolve_patch_path(patch_filename)
  local patch_content = parser.read_patch_file(patch_path)
  local files = parser.extract_files(patch_content)
  if #files == 0 then
    vim.notify("No files to revert", vim.log.levels.WARN)
    return false
  end

  local failed_files = {}
  local success_count = 0

  for _, file in ipairs(files) do
    local success, error_msg = restore_file(context_dir, snapshot_id, file)
    if not success then
      table.insert(failed_files, { file = file, error = error_msg })
    else
      success_count = success_count + 1
    end
  end

  M._report_results(files, failed_files, success_count, snapshot_id)
  M._reload_successful_files(files, failed_files, success_count)

  return success_count > 0
end

---@param files string[]
---@param failed_files { file: string, error: string? }[]
---@param success_count number
---@param snapshot_id string
function M._report_results(files, failed_files, success_count, snapshot_id)
  if #failed_files > 0 then
    local error_msg = string.format("Reverted %d/%d files. Failed files:\n", success_count, #files)
    for _, failure in ipairs(failed_files) do
      error_msg = error_msg .. string.format("  - %s: %s\n", failure.file, failure.error)
    end
    vim.notify(error_msg, vim.log.levels.WARN)
  else
    vim.notify(string.format("Reverted all %d file(s) to snapshot %s", #files, snapshot_id), vim.log.levels.INFO)
  end
end

---@param files string[]
---@param failed_files { file: string, error: string? }[]
---@param success_count number
function M._reload_successful_files(files, failed_files, success_count)
  if success_count == 0 then
    return
  end

  local failed_set = {}
  for _, failure in ipairs(failed_files) do
    failed_set[failure.file] = true
  end

  local success_files = {}
  for _, file in ipairs(files) do
    if not failed_set[file] then
      table.insert(success_files, file)
    end
  end

  local BufferReload = require("vibing.core.utils.buffer_reload")
  BufferReload.reload_files(success_files)
end

return M
