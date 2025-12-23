local git = require("vibing.utils.git")
local diff_util = require("vibing.utils.diff")

---@class Vibing.InlinePreview
---インラインアクションのプレビューUI
---4パネル構成: アクション/指示、ファイルリスト、Diff、レスポンス
local M = {}

---@class Vibing.InlinePreview.State
---@field action string 選択したアクション
---@field instruction string 追加指示
---@field modified_files string[] 変更されたファイル一覧
---@field diffs table<string, table> { [filepath] = { lines, has_delta, error } }
---@field selected_file_idx number 現在選択中のファイルインデックス
---@field response_text string Agent SDKレスポンス
---@field win_action number? アクション表示ウィンドウ
---@field win_instruction number? 指示入力ウィンドウ
---@field win_files number? ファイルリストウィンドウ
---@field win_diff number? Diffプレビューウィンドウ
---@field win_response number? レスポンス表示ウィンドウ
---@field buf_action number? アクション表示バッファ
---@field buf_instruction number? 指示入力バッファ
---@field buf_files number? ファイルリストバッファ
---@field buf_diff number? Diffプレビューバッファ
---@field buf_response number? レスポンス表示バッファ

---@type Vibing.InlinePreview.State
local state = {
  action = "",
  instruction = "",
  modified_files = {},
  diffs = {},
  selected_file_idx = 1,
  response_text = "",
  win_action = nil,
  win_instruction = nil,
  win_files = nil,
  win_diff = nil,
  win_response = nil,
  buf_action = nil,
  buf_instruction = nil,
  buf_files = nil,
  buf_diff = nil,
  buf_response = nil,
}

---プレビューUIをセットアップして表示
---@param action string アクション名（fix, feat, etc.）
---@param instruction string 追加の指示
---@param modified_files string[] 変更されたファイル一覧
---@param response_text string Agent SDKの応答テキスト
---@return boolean success 成功した場合true
function M.setup(action, instruction, modified_files, response_text)
  -- Gitリポジトリチェック
  if not git.is_git_repo() then
    vim.notify(
      "Preview mode requires a Git repository. This project is not under Git version control.",
      vim.log.levels.ERROR
    )
    return false
  end

  -- 変更ファイルチェック
  if not modified_files or #modified_files == 0 then
    vim.notify(
      "No files were modified during this action. Nothing to preview.",
      vim.log.levels.INFO
    )
    return false
  end

  -- 状態初期化
  state.action = action
  state.instruction = instruction or ""
  state.modified_files = modified_files
  state.response_text = response_text or ""
  state.selected_file_idx = 1

  -- Diff取得
  state.diffs = git.get_diffs(modified_files)

  -- Diff取得結果チェック（全てエラーの場合は警告）
  local has_valid_diff = false
  for _, diff_data in pairs(state.diffs) do
    if not diff_data.error then
      has_valid_diff = true
      break
    end
  end

  if not has_valid_diff then
    vim.notify(
      "Failed to retrieve diffs for all modified files. Check Git status.",
      vim.log.levels.WARN
    )
  end

  -- UI構築
  M._create_layout()
  M._render_all()
  M._setup_keymaps()

  return true
end

---ウィンドウレイアウトを作成
function M._create_layout()
  -- レスポンシブ判定（120列以上で横並び）
  local is_wide = vim.o.columns >= 120
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  if is_wide then
    -- 横並びレイアウト
    local action_height = 3
    local response_height = 2
    local files_width = math.floor(total_width * 0.3)
    local diff_width = total_width - files_width - 3 -- 3 for borders
    local middle_height = total_height - action_height - response_height - 4 -- 4 for borders

    -- アクション+指示バッファ（横並び）
    state.buf_action = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_action, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_action, "modifiable", false)

    state.win_action = vim.api.nvim_open_win(state.buf_action, true, {
      relative = "editor",
      width = total_width,
      height = action_height,
      row = start_row,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Inline Preview ",
      title_pos = "center",
    })

    -- ファイルリストバッファ
    state.buf_files = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_files, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

    state.win_files = vim.api.nvim_open_win(state.buf_files, false, {
      relative = "editor",
      width = files_width,
      height = middle_height,
      row = start_row + action_height + 2,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Files ",
      title_pos = "center",
    })

    -- Diffプレビューバッファ
    state.buf_diff = diff_util.create_diff_buffer({})
    state.win_diff = vim.api.nvim_open_win(state.buf_diff, false, {
      relative = "editor",
      width = diff_width,
      height = middle_height,
      row = start_row + action_height + 2,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = " Diff Preview ",
      title_pos = "center",
    })

    -- レスポンスバッファ
    state.buf_response = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_response, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_response, "modifiable", false)
    vim.api.nvim_buf_set_option(state.buf_response, "filetype", "markdown")

    state.win_response = vim.api.nvim_open_win(state.buf_response, false, {
      relative = "editor",
      width = total_width,
      height = response_height,
      row = start_row + total_height - response_height,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Response ",
      title_pos = "center",
    })
  else
    -- 縦並びレイアウト（120列未満）
    local action_height = 3
    local files_height = 6
    local response_height = 2
    local diff_height = total_height - action_height - files_height - response_height - 6

    -- アクションバッファ
    state.buf_action = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_action, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_action, "modifiable", false)

    state.win_action = vim.api.nvim_open_win(state.buf_action, true, {
      relative = "editor",
      width = total_width,
      height = action_height,
      row = start_row,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Inline Preview ",
      title_pos = "center",
    })

    -- ファイルリストバッファ
    state.buf_files = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_files, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

    state.win_files = vim.api.nvim_open_win(state.buf_files, false, {
      relative = "editor",
      width = total_width,
      height = files_height,
      row = start_row + action_height + 2,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Files ",
      title_pos = "center",
    })

    -- Diffプレビューバッファ
    state.buf_diff = diff_util.create_diff_buffer({})
    state.win_diff = vim.api.nvim_open_win(state.buf_diff, false, {
      relative = "editor",
      width = total_width,
      height = diff_height,
      row = start_row + action_height + files_height + 4,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Diff Preview ",
      title_pos = "center",
    })

    -- レスポンスバッファ
    state.buf_response = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_response, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_response, "modifiable", false)
    vim.api.nvim_buf_set_option(state.buf_response, "filetype", "markdown")

    state.win_response = vim.api.nvim_open_win(state.buf_response, false, {
      relative = "editor",
      width = total_width,
      height = response_height,
      row = start_row + total_height - response_height,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Response ",
      title_pos = "center",
    })
  end
end

---全パネルを再描画
function M._render_all()
  M._render_action_panel()
  M._render_files_panel()
  M._render_diff_panel()
  M._render_response_panel()
end

---アクションパネルを描画
function M._render_action_panel()
  if not state.buf_action or not vim.api.nvim_buf_is_valid(state.buf_action) then
    return
  end

  local lines = {
    string.format("Action: [%s]  Instruction: %s", state.action, state.instruction),
    "",
    "[a]ccept  [r]eject  [q]uit",
  }

  vim.api.nvim_buf_set_option(state.buf_action, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf_action, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf_action, "modifiable", false)
end

---ファイルリストパネルを描画
function M._render_files_panel()
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local lines = { string.format("Files (%d):", #state.modified_files), "" }

  for i, file in ipairs(state.modified_files) do
    local marker = (i == state.selected_file_idx) and "▶ " or "  "
    table.insert(lines, marker .. file)
  end

  vim.api.nvim_buf_set_option(state.buf_files, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

  -- 選択行をハイライト
  local ns_id = vim.api.nvim_create_namespace("vibing_inline_preview")
  vim.api.nvim_buf_clear_namespace(state.buf_files, ns_id, 0, -1)
  if state.selected_file_idx > 0 and state.selected_file_idx <= #state.modified_files then
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Visual", state.selected_file_idx + 1, 0, -1)
  end
end

---Diffパネルを描画
function M._render_diff_panel()
  if not state.buf_diff or not vim.api.nvim_buf_is_valid(state.buf_diff) then
    return
  end

  if #state.modified_files == 0 then
    diff_util.update_diff_buffer(state.buf_diff, { "No files modified" })
    return
  end

  local file = state.modified_files[state.selected_file_idx]
  local diff_data = state.diffs[file]

  if not diff_data then
    diff_util.update_diff_buffer(state.buf_diff, { "Error: Diff not available for " .. file })
    return
  end

  if diff_data.error then
    diff_util.update_diff_buffer(state.buf_diff, diff_data.lines)
    return
  end

  diff_util.update_diff_buffer(state.buf_diff, diff_data.lines)
end

---レスポンスパネルを描画
function M._render_response_panel()
  if not state.buf_response or not vim.api.nvim_buf_is_valid(state.buf_response) then
    return
  end

  local lines = { string.format("Response: %s", state.response_text) }

  vim.api.nvim_buf_set_option(state.buf_response, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.buf_response, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf_response, "modifiable", false)
end

---キーマップを設定
function M._setup_keymaps()
  -- j/k: ファイル選択（files/diffウィンドウ）
  for _, win in ipairs({ state.win_files, state.win_diff }) do
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)

      vim.keymap.set("n", "j", function()
        M._on_file_select(1)
      end, { buffer = buf, nowait = true, silent = true })

      vim.keymap.set("n", "k", function()
        M._on_file_select(-1)
      end, { buffer = buf, nowait = true, silent = true })

      vim.keymap.set("n", "<Down>", function()
        M._on_file_select(1)
      end, { buffer = buf, nowait = true, silent = true })

      vim.keymap.set("n", "<Up>", function()
        M._on_file_select(-1)
      end, { buffer = buf, nowait = true, silent = true })
    end
  end

  -- a/r/q/Esc: 全ウィンドウ
  for _, win in ipairs({ state.win_action, state.win_files, state.win_diff, state.win_response }) do
    if win and vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)

      vim.keymap.set("n", "a", M._on_accept, { buffer = buf, nowait = true, silent = true, desc = "Accept changes" })
      vim.keymap.set("n", "r", M._on_reject, { buffer = buf, nowait = true, silent = true, desc = "Reject changes" })
      vim.keymap.set("n", "q", M._on_quit, { buffer = buf, nowait = true, silent = true, desc = "Quit" })
      vim.keymap.set("n", "<Esc>", M._on_quit, { buffer = buf, nowait = true, silent = true, desc = "Quit" })
    end
  end
end

---ファイル選択を変更
---@param direction number 1で次、-1で前
function M._on_file_select(direction)
  local new_idx = state.selected_file_idx + direction

  -- 範囲チェック
  if new_idx < 1 then
    new_idx = #state.modified_files
  elseif new_idx > #state.modified_files then
    new_idx = 1
  end

  state.selected_file_idx = new_idx

  -- 再描画
  M._render_files_panel()
  M._render_diff_panel()

  -- Diffウィンドウにフォーカス
  if state.win_diff and vim.api.nvim_win_is_valid(state.win_diff) then
    vim.api.nvim_set_current_win(state.win_diff)
  end
end

---Accept処理（変更を保持）
function M._on_accept()
  M._close_all()
  vim.notify(
    string.format("Accepted changes to %d files", #state.modified_files),
    vim.log.levels.INFO
  )
end

---Reject処理（変更を元に戻す）
function M._on_reject()
  -- git checkout実行
  local result = git.checkout_files(state.modified_files)

  if result.success then
    vim.notify(
      string.format("Reverted %d files successfully", #state.modified_files),
      vim.log.levels.INFO
    )
  else
    -- 部分的失敗
    local failed_count = #result.errors
    local success_count = #state.modified_files - failed_count

    vim.notify(
      string.format("Reverted %d/%d files. %d failed.", success_count, #state.modified_files, failed_count),
      vim.log.levels.WARN
    )

    -- エラー詳細を表示
    for _, err in ipairs(result.errors) do
      vim.notify(string.format("  - %s: %s", err.file, err.message), vim.log.levels.ERROR)
    end
  end

  M._close_all()
end

---Quit処理（確認なしで閉じる）
function M._on_quit()
  M._close_all()
end

---全UIを破棄
function M._close_all()
  -- ウィンドウを閉じる
  for _, win in ipairs({ state.win_action, state.win_files, state.win_diff, state.win_response }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- バッファを削除
  for _, buf in ipairs({ state.buf_action, state.buf_files, state.buf_diff, state.buf_response }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- 状態をクリア
  state = {
    action = "",
    instruction = "",
    modified_files = {},
    diffs = {},
    selected_file_idx = 1,
    response_text = "",
    win_action = nil,
    win_files = nil,
    win_diff = nil,
    win_response = nil,
    buf_action = nil,
    buf_files = nil,
    buf_diff = nil,
    buf_response = nil,
  }
end

return M
