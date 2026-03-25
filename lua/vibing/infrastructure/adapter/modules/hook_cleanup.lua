--- Cleanup stale hook communication directories from previous sessions
--- @module vibing.infrastructure.adapter.modules.hook_cleanup

local M = {}

--- Remove stale /tmp/vibing-hook-* directories
--- Cleans up leftover .req/.res files from previous vibing.nvim sessions.
--- Skips the directory for the current RPC port (if running).
function M.cleanup_stale_dirs()
  local current_port = nil
  local ok, rpc_server = pcall(require, "vibing.infrastructure.rpc.server")
  if ok then
    current_port = rpc_server.get_port()
  end

  local current_dir_suffix = current_port and tostring(current_port) or nil

  local handle = vim.loop.fs_scandir("/tmp")
  if not handle then
    return
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "directory" and name:match("^vibing%-hook%-") then
      local port_suffix = name:match("^vibing%-hook%-(.+)$")
      if current_dir_suffix and port_suffix == current_dir_suffix then
        M._cleanup_files_in_dir("/tmp/" .. name)
      else
        M._remove_dir_recursive("/tmp/" .. name)
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
