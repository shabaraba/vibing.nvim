---@class Vibing.Presentation.DiffOpener
---`gd`（カーソル下のファイルについて、そのターンの差分を開く）の入口。
---
---表示手段は2つ:
---  - `patch_viewer` のフロート（ファイル一覧 ＋ Before/After のside-by-side、`r`/`R` でrevert）
---  - mini.diff で実ファイル上にインライン表示（`diff.viewer = "mini"` を明示した場合）
---
---既定（`auto`）はフロート。インラインは差分マーカーがmini.diffの `view.style` 任せで、
---広い変更を俯瞰するには弱い。フロート側は自前のウィンドウなので行番号も折り畳みも出せる。
---
---そのターンのpatchが無いときは参照テキストをHEADから取って同じ経路に流す。**見た目が同じで
---意味が違う** ので、そのときだけは理由を通知する。黙って差し替えると、ユーザーには
---「ターンの差分のはずが知らない変更まで出ている」としか見えない。
local M = {}

---設定と実際の環境から、使うビューアを決める
---@return "mini"|"patch"
function M.resolve_viewer()
  -- `setup()` 前は `options` が nil。`gd` は setup 後にしか存在しないキーマップなので実際には
  -- 起きないが、ここが唯一の分岐点なので nil で落とさない
  local config = require("vibing.config")
  local viewer = ((config.options or {}).diff or {}).viewer or "auto"

  if viewer == "mini" and require("vibing.ui.mini_diff").is_available() then
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
---
---ターン単位ではなくHEADとの差分になるので、まずその理由を通知する。表示自体は通常と同じ
---2つのビューアを使う（インライン → フロート）。
---@param buf number チャットバッファ
---@param file_path string
---@param session_id string|nil
function M._show_head_diff(buf, file_path, session_id)
  require("vibing.core.utils.notify").info(
    "No patch for this turn. Showing the diff against HEAD, which is not limited to this turn."
  )

  if M.resolve_viewer() == "mini" then
    local head = require("vibing.core.utils.git_head_text").lines(file_path)
    if require("vibing.ui.mini_diff").show_ref(file_path, head) then
      return
    end
  end

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
    if file_path and M.resolve_viewer() == "mini" and M._show_inline(patch_filename, file_path) then
      return
    end
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
