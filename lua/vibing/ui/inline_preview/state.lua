---@class Vibing.InlinePreview.State
---@field mode "inline"|"chat" 表示モード（inline: 3パネル、chat: 2パネル）
---@field modified_files string[] 変更されたファイル一覧
---@field diffs table<string, table> { [filepath] = { lines, has_delta, error } }
---@field selected_file_idx number 現在選択中のファイルインデックス
---@field response_text string Agent SDKレスポンス（chatモードでは空）
---@field active_panel "diff"|"response" 現在展開中のパネル（inlineモードのみ）
---@field saved_contents table<string, string[]> Claude変更前のファイル内容 { [filepath] = lines }
---@field user_prompt string? ユーザーが入力したプロンプト（振り返りファイル保存用）
---@field action string? 実行されたアクション名（fix, feat等）
---@field instruction string? 追加指示
---@field session_id string? セッションID（会話継続用）
---@field win_files number? ファイルリストウィンドウ
---@field win_diff number? Diffプレビューウィンドウ
---@field win_response number? レスポンス表示ウィンドウ（inlineモードのみ）
---@field buf_files number? ファイルリストバッファ
---@field buf_diff number? Diffプレビューバッファ
---@field buf_response number? レスポンス表示バッファ（inlineモードのみ）

local M = {}

---@type Vibing.InlinePreview.State
local state = {
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

---状態を取得
---@return Vibing.InlinePreview.State
function M.get()
  return state
end

---状態を初期化
---@param mode "inline"|"chat"
---@param modified_files string[]
---@param response_text string
---@param saved_contents table<string, string[]>?
---@param user_prompt string?
---@param action string?
---@param instruction string?
---@param session_id string?
function M.init(mode, modified_files, response_text, saved_contents, user_prompt, action, instruction, session_id)
  state.mode = mode
  state.modified_files = modified_files or {}
  state.response_text = response_text or ""
  state.saved_contents = saved_contents or {}
  state.user_prompt = user_prompt
  state.action = action
  state.instruction = instruction
  state.session_id = session_id
  state.selected_file_idx = 1
  state.active_panel = "diff"
  state.diffs = {}
end

---状態をリセット
function M.reset()
  state.modified_files = {}
  state.diffs = {}
  state.selected_file_idx = 1
  state.response_text = ""
  state.active_panel = "diff"
  state.saved_contents = {}
  state.user_prompt = nil
  state.action = nil
  state.instruction = nil
  state.session_id = nil
  state.win_files = nil
  state.win_diff = nil
  state.win_response = nil
  state.buf_files = nil
  state.buf_diff = nil
  state.buf_response = nil
end

return M
