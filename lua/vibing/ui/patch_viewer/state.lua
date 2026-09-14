---@class Vibing.PatchViewer.State
---@field session_id string?
---@field patch_filename string?
---@field patch_content string?
---@field base_dir string? patch内パスの基準ディレクトリ。無いのは旧mote形式のpatch
---@field files string[]
---@field stats table[] `files` と同じ並びの変更量。開く時に一度だけ数える
---@field selected_idx number
---@field layout "split"|"unified" Beforeペインを作るかどうか。`s` で切り替わる
---@field saved_diffopt string? diffモードに入る前のグローバル `diffopt`。閉じる時に戻す
---@field win_files number?
---@field win_before number?
---@field win_after number?
---@field buf_files number?
---@field buf_before number?
---@field buf_after number? Afterペインに今出ているバッファ。実ファイルのこともある
---@field after_mapped number? ビューア用キーを張った実ファイルのバッファ。閉じる時に外す
---@field after_saved_maps table[]? 張る前からそのバッファに在ったマッピング。閉じる時に戻す
local M = {
  session_id = nil,
  patch_filename = nil,
  patch_content = nil,
  base_dir = nil,
  files = {},
  stats = {},
  selected_idx = 1,
  layout = "split",
  saved_diffopt = nil,
  win_files = nil,
  win_before = nil,
  win_after = nil,
  buf_files = nil,
  buf_before = nil,
  buf_after = nil,
  after_mapped = nil,
  after_saved_maps = nil,
}

---@return Vibing.PatchViewer.State
function M.reset()
  M.session_id = nil
  M.patch_filename = nil
  M.patch_content = nil
  M.base_dir = nil
  M.files = {}
  M.stats = {}
  M.selected_idx = 1
  M.layout = "split"
  M.saved_diffopt = nil
  M.win_files = nil
  M.win_before = nil
  M.win_after = nil
  M.buf_files = nil
  M.buf_before = nil
  M.buf_after = nil
  M.after_mapped = nil
  M.after_saved_maps = nil
  return M
end

return M
