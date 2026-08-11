--- Cleanup stale hook communication directories from previous sessions
--- @module vibing.infrastructure.adapter.modules.hook_cleanup

local M = {}

--- Remove stale /tmp/vibing-hook-* directories
--- Cleans up leftover .req/.res files from previous vibing.nvim sessions.
--- Skips the directory for the current RPC port (if running).
function M.cleanup_stale_dirs()
  local CommDir = require("vibing.infrastructure.rpc.comm_dir")
  local current_dir = CommDir.path()

  local handle = vim.loop.fs_scandir(CommDir.ROOT)
  if not handle then
    return
  end

  local prefix_pattern = "^" .. vim.pesc(CommDir.PREFIX)

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "directory" and name:match(prefix_pattern) then
      local dir = CommDir.ROOT .. "/" .. name
      if dir == current_dir then
        M._cleanup_files_in_dir(dir)
      else
        M._remove_dir_recursive(dir)
      end
    end
  end
end

--- Remove only .req and .res files inside a directory (keep dir alive)
--- @param dir string
function M._cleanup_files_in_dir(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if name:match("%.req$") or name:match("%.res$") or name:match("%.tmp$") then
      os.remove(dir .. "/" .. name)
    end
  end
end

--- Remove a directory and all its contents
--- @param dir string
function M._remove_dir_recursive(dir)
  local handle = vim.loop.fs_scandir(dir)
  if not handle then
    return
  end
  while true do
    local name = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    os.remove(dir .. "/" .. name)
  end
  vim.loop.fs_rmdir(dir)
end

return M
