local M = {}

-- プレビュー用のデータを保持
local preview_state = {
  modified_files = nil,
  saved_contents = nil,
}

---最後に変更されたファイル一覧を設定
---@param modified_files string[] 変更されたファイルパス
---@param saved_contents table<string, string[]>? Claude変更前のファイル内容
function M.set_modified_files(modified_files, saved_contents)
  preview_state.modified_files = modified_files
  preview_state.saved_contents = saved_contents
end

---最後に変更されたファイル一覧を取得
---@return string[]?
function M.get_modified_files()
  return preview_state.modified_files
end

---保存されたファイル内容を取得
---@return table<string, string[]>?
function M.get_saved_contents()
  return preview_state.saved_contents
end

---プレビューデータをクリア
function M.clear()
  preview_state.modified_files = nil
  preview_state.saved_contents = nil
end

return M
