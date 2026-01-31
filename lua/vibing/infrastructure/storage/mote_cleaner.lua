---@class Vibing.Infrastructure.Storage.MoteCleaner
local M = {}

local notify = require("vibing.core.utils.notify")
local MoteContext = require("vibing.core.utils.mote.context")
local MoteBinary = require("vibing.core.utils.mote.binary")

---@param file_path string
---@return string[]
function M._extract_patch_refs(file_path)
  local patch_files = {}
  if vim.fn.filereadable(file_path) ~= 1 then
    return patch_files
  end

  local lines = vim.fn.readfile(file_path)
  for _, line in ipairs(lines) do
    local patch_path = line:match("<!%-%- patch: ([^%s]+) %-%-?>")
    if patch_path then
      table.insert(patch_files, patch_path)
    end
  end
  return patch_files
end

---@param patch_ref string
---@param context_dir string
---@return string
function M._resolve_patch_path(patch_ref, context_dir)
  if patch_ref:match("^%.vibing/") then
    return vim.fn.fnamemodify(patch_ref, ":p")
  end
  return context_dir .. "/patches/" .. patch_ref
end

---@param file_path string
---@param config table {project: string, context: string, cwd: string}
---@param callback fun(success: boolean, error: string?)
function M.clean_snapshot(file_path, config, callback)
  local patch_files = M._extract_patch_refs(file_path)

  local context_dir = MoteContext.build_dir_path(config.project, config.context)
  if not context_dir then
    callback(true, nil)
    return
  end

  local deleted_count = 0
  for _, patch_ref in ipairs(patch_files) do
    local patch_path = M._resolve_patch_path(patch_ref, context_dir)

    if vim.fn.filereadable(patch_path) == 1 then
      local ok = pcall(vim.fn.delete, patch_path)
      if ok then
        deleted_count = deleted_count + 1
      end
    end
  end

  if deleted_count > 0 then
    vim.schedule(function()
      notify.info(string.format("Deleted %d patch file(s) for: %s", deleted_count, vim.fn.fnamemodify(file_path, ":t")))
    end)
  end

  M._delete_snapshots_containing_file(file_path, context_dir, function(snap_deleted_count)
    if snap_deleted_count > 0 then
      vim.schedule(function()
        notify.info(
          string.format("Deleted %d snapshot(s) containing: %s", snap_deleted_count, vim.fn.fnamemodify(file_path, ":t"))
        )
      end)

      M._run_gc(context_dir, function()
        callback(true, nil)
      end)
    else
      callback(true, nil)
    end
  end)
end

---@param context_dir string
---@param callback fun(success: boolean)
function M._run_gc(context_dir, callback)
  local mote_binary = MoteBinary.get_path()
  if not mote_binary then
    callback(false)
    return
  end

  vim.fn.jobstart({ mote_binary, "snap", "gc", "-d", context_dir }, {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        vim.schedule(function()
          notify.info("Garbage collection completed: Cleaned up unreferenced objects")
        end)
        callback(true)
      else
        callback(false)
      end
    end,
    stdout_buffered = true,
    stderr_buffered = true,
  })
end

---@param file_path string
---@param context_dir string
---@param callback fun(deleted_count: number)
function M._delete_snapshots_containing_file(file_path, context_dir, callback)
  local snapshots_dir = context_dir .. "/storage/snapshots"

  if vim.fn.isdirectory(snapshots_dir) ~= 1 then
    callback(0)
    return
  end

  local git_root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
  local relative_path = vim.fn.fnamemodify(file_path, ":p"):gsub("^" .. vim.pesc(git_root .. "/"), "")

  local handle = vim.loop.fs_scandir(snapshots_dir)
  if not handle then
    callback(0)
    return
  end

  local deleted_count = 0
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end

    if type == "file" and name:match("%.json$") then
      local snapshot_file = snapshots_dir .. "/" .. name
      local ok, content = pcall(vim.fn.readfile, snapshot_file)
      if ok and content then
        local json_str = table.concat(content, "\n")
        if json_str:find('"path"%s*:%s*"' .. vim.pesc(relative_path) .. '"') then
          local delete_ok = pcall(vim.fn.delete, snapshot_file)
          if delete_ok then
            deleted_count = deleted_count + 1
          end
        end
      end
    end
  end

  callback(deleted_count)
end

---@param entities Vibing.Domain.Chat.FileEntity[]
---@param config table
---@param callback fun(success_count: number, failed_count: number, errors: string[])
function M.clean_batch(entities, config, callback)
  local total = #entities
  local completed = 0
  local success_count = 0
  local failed_count = 0
  local errors = {}

  if total == 0 then
    callback(0, 0, {})
    return
  end

  for _, entity in ipairs(entities) do
    M.clean_snapshot(entity.path, config, function(success, error)
      completed = completed + 1

      if success then
        success_count = success_count + 1
      else
        failed_count = failed_count + 1
        table.insert(errors, error or "Unknown error")
      end

      if completed == total then
        callback(success_count, failed_count, errors)
      end
    end)
  end
end

return M
