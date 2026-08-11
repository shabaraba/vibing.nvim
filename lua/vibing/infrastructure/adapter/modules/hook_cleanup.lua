--- Cleanup stale hook communication directories from previous sessions
--- @module vibing.infrastructure.adapter.modules.hook_cleanup

local M = {}

--- Comm directories owned by a Neovim that is still running.
--- `registry.list()` already drops entries whose PID is gone, so whatever it returns is live.
--- @return table<string, boolean> set of directory paths
local function live_comm_dirs()
  local ok, dirs = pcall(function()
    local registry = require("vibing.infrastructure.rpc.registry")
    local CommDir = require("vibing.infrastructure.rpc.comm_dir")
    local result = {}
    for _, instance in ipairs(registry.list()) do
      if instance.port then
        result[CommDir.for_port(instance.port)] = true
      end
    end
    return result
  end)
  return ok and dirs or {}
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

  -- Sweep our own directory up front: $VIBING_HOOK_COMM_DIR can put it outside ROOT, where the
  -- scan below would never reach it.
  M._cleanup_files_in_dir(current_dir)

  local handle = vim.loop.fs_scandir(CommDir.ROOT)
  if not handle then
    return
  end

  local prefix_pattern = "^" .. vim.pesc(CommDir.PREFIX)
  local in_use

  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then
      break
    end
    if type == "directory" and name:match(prefix_pattern) then
      local dir = CommDir.ROOT .. "/" .. name
      if dir ~= current_dir then
        -- Built on the first leftover found: with none (the usual startup) we skip the scan.
        in_use = in_use or live_comm_dirs()
        if not in_use[dir] then
          M._remove_dir_recursive(dir)
        end
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
    -- .fail is written by stop-failure.sh and consumed by the rate_limit handler; if that
    -- handler never ran (Neovim was already gone), the file would otherwise stay forever.
    if name:match("%.req$") or name:match("%.res$") or name:match("%.tmp$") or name:match("%.fail$") then
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
