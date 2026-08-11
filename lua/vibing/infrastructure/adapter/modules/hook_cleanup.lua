--- Cleanup stale hook communication directories from previous sessions
--- @module vibing.infrastructure.adapter.modules.hook_cleanup

local M = {}

--- Comm directories owned by a Neovim that is still running.
--- `registry.list()` already drops entries whose PID is gone, so whatever it returns is live.
--- @return table<string, boolean> set of directory paths
local function live_comm_dirs()
  local ok_registry, registry = pcall(require, "vibing.infrastructure.rpc.registry")
  if not ok_registry then
    return {}
  end

  local CommDir = require("vibing.infrastructure.rpc.comm_dir")
  local dirs = {}
  local ok_list, instances = pcall(registry.list)
  if not ok_list then
    return {}
  end

  for _, instance in ipairs(instances) do
    if instance.port then
      dirs[CommDir.for_port(instance.port)] = true
    end
  end
  return dirs
end

--- Remove stale /tmp/vibing-hook-* directories
--- Cleans up leftover .req/.res files from previous vibing.nvim sessions.
--- "Stale" means the owning Neovim is gone: this instance's own directory is only swept of
--- leftover files, and a directory belonging to another *running* instance is left completely
--- alone. Deleting those would destroy in-flight hook requests of a healthy concurrent session
--- (see "Concurrent Execution Support" in architecture.md).
function M.cleanup_stale_dirs()
  local CommDir = require("vibing.infrastructure.rpc.comm_dir")
  local current_dir = CommDir.path()
  local in_use = live_comm_dirs()

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
      elseif not in_use[dir] then
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
