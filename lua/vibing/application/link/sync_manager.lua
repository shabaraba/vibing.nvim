---@class Vibing.Application.Link.SyncManager
local M = {}

local notify = require("vibing.core.utils.notify")

---@class Vibing.Application.Link.SyncResult
---@field total number
---@field updated number
---@field failed number

---@param old_path string
---@param new_path string
---@param scanners Vibing.Infrastructure.Link.Scanner[]
---@param base_dir string
---@return Vibing.Application.Link.SyncResult
function M.sync_links(old_path, new_path, scanners, base_dir)
  local total_updated = 0
  local total_failed = 0
  local total_scanned = 0

  for _, scanner in ipairs(scanners) do
    local files = scanner:find_target_files(base_dir)

    for _, file in ipairs(files) do
      total_scanned = total_scanned + 1

      if scanner:contains_link(file, old_path) then
        local success, err = scanner:update_link(file, old_path, new_path)

        if success then
          total_updated = total_updated + 1
        else
          total_failed = total_failed + 1
          notify.error(
            string.format("Failed to update %s: %s", vim.fn.fnamemodify(file, ":."), err or "unknown"),
            "Link Sync"
          )
        end
      end
    end
  end

  return {
    total = total_scanned,
    updated = total_updated,
    failed = total_failed,
  }
end

return M
