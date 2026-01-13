---@class Vibing.InlinePreview.State
---@field mode "inline"|"chat" 表示モード（inline: 3パネル、chat: 2パネル）
---@field modified_files string[] 変更されたファイル一覧
---@field diffs table<string, table> { [filepath] = { lines, has_delta, error } }
---@field selected_file_idx number 現在選択中のファイルインデックス
---@field response_text string Agent SDKレスポンス（chatモードでは空）
---@field active_panel "diff"|"response" 現在展開中のパネル（inlineモードのみ）
---@field saved_contents table<string, string[]> Claude変更前のファイル内容 { [filepath] = lines }
---@field user_prompt string? ユーザーが入力したプロンプト
---@field action string? 実行されたアクション名
---@field instruction string? 追加指示
---@field session_id string? セッションID
---@field win_files number? ファイルリストウィンドウ
---@field win_diff number? Diffプレビューウィンドウ
---@field win_response number? レスポンス表示ウィンドウ
---@field buf_files number? ファイルリストバッファ
---@field buf_diff number? Diffプレビューバッファ
---@field buf_response number? レスポンス表示バッファ

local M = {}

---@type Vibing.InlinePreview.State
M.data = {
  mode = "inline",
  modified_files = {},
  diffs = {},
  selected_file_idx = 1,
  response_text = "",
  active_panel = "diff",
  saved_contents = {},
  user_prompt = nil,
  action = nil,
  instruction = nil,
  session_id = nil,
  win_files = nil,
  win_diff = nil,
  win_response = nil,
  buf_files = nil,
  buf_diff = nil,
  buf_response = nil,
}

---状態を初期化
---@param opts table
function M.init(opts)
  M.data.mode = opts.mode or "inline"
  M.data.modified_files = opts.modified_files or {}
  M.data.response_text = opts.response_text or ""
  M.data.saved_contents = opts.saved_contents or {}
  M.data.user_prompt = opts.user_prompt
  M.data.action = opts.action
  M.data.instruction = opts.instruction
  M.data.session_id = opts.session_id
  M.data.selected_file_idx = opts.initial_idx or 1
  M.data.diffs = {}
  M.data.active_panel = "diff"
end

---状態をリセット
function M.reset()
  M.data = {
    mode = "inline",
    modified_files = {},
    diffs = {},
    selected_file_idx = 1,
    response_text = "",
    active_panel = "diff",
    saved_contents = {},
    user_prompt = nil,
    action = nil,
    instruction = nil,
    session_id = nil,
    win_files = nil,
    win_diff = nil,
    win_response = nil,
    buf_files = nil,
    buf_diff = nil,
    buf_response = nil,
  }
end

---現在選択中のファイルパスを取得
---@return string?
function M.get_selected_file()
  if #M.data.modified_files == 0 then
    return nil
  end
  return M.data.modified_files[M.data.selected_file_idx]
end

---ファイルインデックスを更新（範囲チェック付き）
---@param idx number
function M.set_selected_file_idx(idx)
  if idx < 1 then
    idx = 1
  elseif idx > #M.data.modified_files then
    idx = #M.data.modified_files
  end
  M.data.selected_file_idx = idx
end

---次/前のファイルに移動
---@param direction "next"|"prev"
function M.move_file_selection(direction)
  local new_idx = M.data.selected_file_idx
  if direction == "next" then
    new_idx = new_idx + 1
  elseif direction == "prev" then
    new_idx = new_idx - 1
  end
  M.set_selected_file_idx(new_idx)
end

return M
