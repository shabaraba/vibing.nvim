---@class Vibing.UI.PatchViewer
---ターンのpatchを開くフロート。組み立てと後片付けだけを持ち、キーが呼ぶ操作は `actions.lua`。
local M = {}

local state = require("vibing.ui.patch_viewer.state")
local parser = require("vibing.ui.patch_viewer.parser")
local window = require("vibing.ui.patch_viewer.window")
local diff_mode = require("vibing.ui.patch_viewer.diff_mode")
local keymaps = require("vibing.ui.patch_viewer.keymaps")
local actions = require("vibing.ui.patch_viewer.actions")
local revert = require("vibing.ui.patch_viewer.revert")

---今開いているビューアのコールバック。Afterペインのキーは選択のたびに張り直すので、
---`show` の時に作ったものをここで持ち回る
---@type table|nil
local callbacks = nil

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
  state.base_dir = parser.extract_base_dir(patch_content)
  state.files = files
  state.stats = parser.all_stats(patch_content, files)
  state.selected_idx = 1
  state.layout = actions.initial_layout()

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
  callbacks = M._create_callbacks()
  keymaps.setup(state, callbacks)
  actions.refresh(state, callbacks)
end

---@return table
function M._create_callbacks()
  local cb
  cb = {
    select_file = function(direction)
      actions.select_file(state, cb, direction)
    end,
    select_from_cursor = function()
      actions.select_from_cursor(state, cb)
    end,
    open_file = function()
      actions.open_selected_file(state, M._close)
    end,
    toggle_layout = function()
      actions.toggle_layout(state, cb)
    end,
    cycle_window = function(direction)
      window.cycle_window(state, direction)
    end,
    revert = function()
      actions.revert_selected(state, M._close)
    end,
    revert_all = function()
      actions.revert_all(state, M._close)
    end,
    close = function()
      M._close()
    end,
  }
  return cb
end

function M._close()
  -- 実ファイルのバッファに焼いたキーを先に外す。ウィンドウを閉じてからでは
  -- `state.after_mapped` ごとresetされて外し損ねる
  keymaps.clear_after(state)
  diff_mode.leave(state)
  window.close_windows(state)
  state.reset()
  callbacks = nil
end

-- テストと既存の呼び出し元が使う薄い入口
function M._select_file(direction)
  actions.select_file(state, callbacks or M._create_callbacks(), direction)
end

function M._select_file_from_cursor()
  actions.select_from_cursor(state, callbacks or M._create_callbacks())
end

function M._toggle_layout()
  actions.toggle_layout(state, callbacks or M._create_callbacks())
end

M.revert_single_file = function(session_id, patch_filename)
  if not state.files or #state.files == 0 or not state.files[state.selected_idx] then
    vim.notify("No file selected", vim.log.levels.WARN)
    return false
  end
  return revert.revert_single_file(session_id, patch_filename, state.files[state.selected_idx])
end

M.revert_all_files = revert.revert_all_files
M.extract_file_diff = parser.extract_file_diff
M._extract_files_from_patch = parser.extract_files

return M
