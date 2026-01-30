---@class Vibing.UI.PatchViewer
local M = {}

local state = require("vibing.ui.patch_viewer.state")
local parser = require("vibing.ui.patch_viewer.parser")
local window = require("vibing.ui.patch_viewer.window")
local ui = require("vibing.ui.patch_viewer.ui")
local keymaps = require("vibing.ui.patch_viewer.keymaps")
local revert = require("vibing.ui.patch_viewer.revert")

---@param session_id string
---@param patch_filename string
---@param target_file? string
function M.show(session_id, patch_filename, target_file)
  local patch_path = parser.resolve_patch_path(patch_filename)
  if not patch_path then
    vim.notify("Patch file not found: " .. patch_filename, vim.log.levels.WARN)
    return
  end

  local patch_content = parser.read_patch_file(patch_path)
  if not patch_content or patch_content == "" then
    vim.notify("Patch file is empty", vim.log.levels.WARN)
    return
  end

  local files = parser.extract_files(patch_content)
  if #files == 0 then
    vim.notify("No files found in patch", vim.log.levels.WARN)
    return
  end

  state.session_id = session_id
  state.patch_filename = patch_filename
  state.patch_content = patch_content
  state.files = files
  state.selected_idx = 1

  if target_file then
    local normalized_target = vim.fn.fnamemodify(target_file, ":.")
    for i, file in ipairs(files) do
      if file == normalized_target or vim.fn.fnamemodify(file, ":.") == normalized_target then
        state.selected_idx = i
        break
      end
    end
  end

  window.create_layout(state)
  ui.render_all(state)
  keymaps.setup(state, M._create_callbacks())
end

---@return table
function M._create_callbacks()
  return {
    select_file = function(direction)
      M._select_file(direction)
    end,
    select_from_cursor = function()
      M._select_file_from_cursor()
    end,
    cycle_window = function(direction)
      window.cycle_window(state, direction)
    end,
    revert = function()
      M._on_revert()
    end,
    revert_all = function()
      M._on_revert_all()
    end,
    close = function()
      M._close()
    end,
  }
end

---@param direction number
function M._select_file(direction)
  local new_idx = state.selected_idx + direction
  if new_idx < 1 then
    new_idx = #state.files
  elseif new_idx > #state.files then
    new_idx = 1
  end
  state.selected_idx = new_idx
  ui.render_all(state)
end

function M._select_file_from_cursor()
  if not state.win_files or not vim.api.nvim_win_is_valid(state.win_files) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win_files)
  local file_idx = cursor[1] - 2
  if file_idx >= 1 and file_idx <= #state.files then
    state.selected_idx = file_idx
    ui.render_all(state)
  end
end

function M._on_revert()
  if not state.session_id or not state.patch_filename then
    vim.notify("No patch to revert", vim.log.levels.WARN)
    return
  end
  if not state.files or #state.files == 0 or not state.files[state.selected_idx] then
    vim.notify("No file selected", vim.log.levels.WARN)
    return
  end
  local selected_file = state.files[state.selected_idx]
  local success = revert.revert_single_file(state.session_id, state.patch_filename, selected_file)
  if success then
    M._close()
  end
end

function M._on_revert_all()
  if not state.session_id or not state.patch_filename then
    vim.notify("No patch to revert", vim.log.levels.WARN)
    return
  end
  local file_count = #state.files
  local choice = vim.fn.confirm(
    string.format("Revert all %d file(s) in this patch?", file_count),
    "&Yes\n&No",
    2
  )
  if choice ~= 1 then
    return
  end
  local success = revert.revert_all_files(state.session_id, state.patch_filename)
  if success then
    M._close()
  end
end

function M._close()
  window.close_windows(state)
  state.reset()
end

-- Public API compatibility
M.revert_single_file = function(session_id, patch_filename)
  local s = require("vibing.ui.patch_viewer.state")
  if not s.files or #s.files == 0 or not s.files[s.selected_idx] then
    vim.notify("No file selected", vim.log.levels.WARN)
    return false
  end
  return revert.revert_single_file(session_id, patch_filename, s.files[s.selected_idx])
end

M.revert_all_files = revert.revert_all_files

M.extract_file_diff = parser.extract_file_diff

M._extract_files_from_patch = parser.extract_files

return M
