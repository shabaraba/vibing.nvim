---@class Vibing.Presentation.DiffOpener
---`gd`（カーソル下のファイルについて、そのターンの差分を開く）の入口。
---
---表示手段は3つあり、上から順に試す:
---  1. mini.diff で実ファイル上にインライン表示（`diff.viewer` が許し、mini.diffがある場合）
---  2. `patch_viewer` のフロート（ファイル一覧＋diffプレビュー、`r`/`R` でrevert）
---  3. patchが見つからないときだけ、HEADとの `git diff`（`diff_selector`）
---
---1と2はどちらも **そのターンのpatch** を見るが、3はHEADとの差分なのでターン単位ではない。
---その違いは `diff_selector` 側に書いてある。
local M = {}

---設定と実際の環境から、使うビューアを決める
---@return "mini"|"patch"
function M.resolve_viewer()
  -- `setup()` 前は `options` が nil。`gd` は setup 後にしか存在しないキーマップなので実際には
  -- 起きないが、ここが唯一の分岐点なので nil で落とさない
  local config = require("vibing.config")
  local viewer = ((config.options or {}).diff or {}).viewer or "auto"

  if viewer == "patch" then
    return "patch"
  end

  local MiniDiff = require("vibing.ui.mini_diff")
  if MiniDiff.is_available() then
    return "mini"
  end

  if viewer == "mini" then
    -- 明示的に選ばれているのに使えないのは設定ミス。黙ってフォールバックすると、ユーザーは
    -- 「設定したのに何も変わらない」としか分からない
    require("vibing.core.utils.notify").warn_once(
      "config.diff.viewer",
      'diff.viewer = "mini" but mini.diff is not installed. Falling back to the patch viewer. '
        .. "Install nvim-mini/mini.diff, or set diff.viewer = \"patch\" to silence this."
    )
  end

  return "patch"
end

---patchをmini.diffでインライン表示する
---@param patch_filename string
---@param file_path string
---@return boolean shown falseなら呼び出し側がpatch_viewerにフォールバックする
function M._show_inline(patch_filename, file_path)
  local parser = require("vibing.ui.patch_viewer.parser")

  local patch_path = parser.resolve_patch_path(patch_filename)
  if not patch_path then
    return false
  end

  local patch_content = parser.read_patch_file(patch_path)
  if not patch_content or patch_content == "" then
    return false
  end

  -- baseヘッダが無いのは削除されたmote統合が書いた古いpatch。逆適用できる自己完結したdiffでは
  -- ないので、ここでは扱えない（patch_viewerは表示だけならできるので、そちらに流す）
  local base_dir = parser.extract_base_dir(patch_content)
  if not base_dir then
    return false
  end

  return require("vibing.ui.mini_diff").show(base_dir, patch_content, file_path)
end

---patchが見つからないときのフォールバック
---@param buf number チャットバッファ
---@param file_path string
---@param session_id string|nil
function M._show_git_diff(buf, file_path, session_id)
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

  local file_path = FilePath.is_cursor_on_file_path(buf)
  if not file_path then
    vim.notify("No file path under cursor", vim.log.levels.INFO)
    return
  end

  local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")
  local session_id = PatchFinder.get_session_id(buf)
  local patch_filename = PatchFinder.find_nearest_patch(buf)

  if session_id and patch_filename then
    if M.resolve_viewer() == "mini" and M._show_inline(patch_filename, file_path) then
      return
    end
    require("vibing.ui.patch_viewer").show(session_id, patch_filename, file_path)
    return
  end

  M._show_git_diff(buf, file_path, session_id)
end

return M
