---@class Vibing.PatchViewer.State
---@field session_id string?
---@field patch_filename string?
---@field patch_content string?
---@field files string[]
---@field selected_idx number
---@field win_files number?
---@field win_diff number?
---@field buf_files number?
---@field buf_diff number?
local M = {
  session_id = nil,
  patch_filename = nil,
  patch_content = nil,
  files = {},
  selected_idx = 1,
  win_files = nil,
  win_diff = nil,
  buf_files = nil,
  buf_diff = nil,
}

---@return Vibing.PatchViewer.State
function M.reset()
  M.session_id = nil
  M.patch_filename = nil
  M.patch_content = nil
  M.files = {}
  M.selected_idx = 1
  M.win_files = nil
  M.win_diff = nil
  M.buf_files = nil
  M.buf_diff = nil
  return M
end

return M
