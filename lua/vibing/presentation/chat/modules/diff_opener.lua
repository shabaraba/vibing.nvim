---@class Vibing.Presentation.DiffOpener
---`gd`（カーソル下のファイルについて、そのターンの差分を開く）の入口。
---
---表示先は `patch_viewer` のフロート1つ（ファイル一覧 ＋ Before/After のside-by-side、
---`s` でunified、`r`/`R` でrevert）。
---
---そのターンのpatchが無いときはHEADとの差分に落ちる。**見た目が同じで意味が違う** ので、
---そのときだけは理由を通知する。黙って差し替えると、ユーザーには「ターンの差分のはずが
---知らない変更まで出ている」としか見えない。
local M = {}

---patchが見つからないときのフォールバック
---
---ターン単位ではなくHEADとの差分になるので、まずその理由を通知する。
---@param buf number チャットバッファ
---@param file_path string
---@param session_id string|nil
function M._show_head_diff(buf, file_path, session_id)
  require("vibing.core.utils.notify").info(
    "No patch for this turn. Showing the diff against HEAD, which is not limited to this turn."
  )

  local DiffSelector = require("vibing.core.utils.diff_selector")
  local view = require("vibing.presentation.chat.view")

  local cwd = nil
  local chat_buf = view.get_chat_buffer(buf)
  if chat_buf then
    cwd = chat_buf:get_cwd()
  end

  DiffSelector.show_diff(file_path, session_id, cwd)
end

---@param buf number チャットバッファ
function M.open(buf)
  local FilePath = require("vibing.core.utils.file_path")
  local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")

  local session_id = PatchFinder.get_session_id(buf)
  local patch_filename = PatchFinder.find_nearest_patch(buf)
  -- 1行サマリの節では個別のパスが取れない。旧形式のチャット（ファイルが1行ずつ並ぶ）と、
  -- 節の外から押された場合のために残す
  local file_path = FilePath.is_cursor_on_file_path(buf)

  if session_id and patch_filename then
    require("vibing.ui.patch_viewer").show(session_id, patch_filename, file_path)
    return
  end

  if not file_path then
    vim.notify("No file path under cursor", vim.log.levels.INFO)
    return
  end

  M._show_head_diff(buf, file_path, session_id)
end

return M
