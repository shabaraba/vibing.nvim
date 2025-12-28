local git = require("vibing.utils.git")
local diff_util = require("vibing.utils.diff")
local BufferReload = require("vibing.utils.buffer_reload")
local BufferIdentifier = require("vibing.utils.buffer_identifier")
local Timestamp = require("vibing.utils.timestamp")

---@class Vibing.InlinePreview
---インラインアクションとチャットのプレビューUI
---inlineモード: 3パネル構成（Files, Diff, Response）
---chatモード: 2パネル構成（Files, Diff）
local M = {}

---@class Vibing.InlinePreview.State
---@field mode "inline"|"chat" 表示モード（inline: 3パネル、chat: 2パネル）
---@field modified_files string[] 変更されたファイル一覧
---@field diffs table<string, table> { [filepath] = { lines, has_delta, error } }
---@field selected_file_idx number 現在選択中のファイルインデックス
---@field response_text string Agent SDKレスポンス（chatモードでは空）
---@field active_panel "diff"|"response" 現在展開中のパネル（inlineモードのみ）
---@field saved_contents table<string, string[]> Claude変更前のファイル内容 { [filepath] = lines }
---@field user_prompt string? ユーザーが入力したプロンプト（振りファイル保存用）
---@field action string? 実行されたアクション名（fix, feat等）
---@field instruction string? 追加指示
---@field session_id string? セッションID（会話継続用）
---@field win_files number? ファイルリストウィンドウ
---@field win_diff number? Diffプレビューウィンドウ
---@field win_response number? レスポンス表示ウィンドウ（inlineモードのみ）
---@field buf_files number? ファイルリストバッファ
---@field buf_diff number? Diffプレビューバッファ
---@field buf_response number? レスポンス表示バッファ（inlineモードのみ）

---@type Vibing.InlinePreview.State
local state = {
  mode = "inline",
  modified_files = {},
  diffs = {},
  selected_file_idx = 1,
  response_text = "",
  active_panel = "diff",  -- デフォルトでDiffを展開
  saved_contents = {},  -- Claude変更前のファイル内容
  user_prompt = nil,  -- ユーザープロンプト
  action = nil,  -- アクション名
  instruction = nil,  -- 追加指示
  session_id = nil,  -- セッションID
  win_files = nil,
  win_diff = nil,
  win_response = nil,
  buf_files = nil,
  buf_diff = nil,
  buf_response = nil,
}

---プレビューUIをセットアップして表示
---@param mode "inline"|"chat" 表示モード
---@param modified_files string[] 変更されたファイル一覧
---@param response_text string Agent SDKの応答テキスト（chatモードでは空文字列）
---@param saved_contents table<string, string[]>? Claude変更前のファイル内容（オプション）
---@param initial_file string? 初期選択するファイルパス（オプション）
---@param user_prompt string? ユーザーが入力したプロンプト（オプション）
---@param action string? 実行されたアクション名（オプション）
---@param instruction string? 追加指示（オプション）
---@param session_id string? セッションID（オプション）
---@return boolean success 成功した場合true
function M.setup(mode, modified_files, response_text, saved_contents, initial_file, user_prompt, action, instruction, session_id)
  -- Gitリポジトリチェック
  if not git.is_git_repo() then
    vim.notify(
      "Preview mode requires a Git repository. This project is not under Git version control.",
      vim.log.levels.ERROR
    )
    return false
  end

  -- 状態初期化
  state.mode = mode
  state.modified_files = modified_files or {}
  state.response_text = response_text or ""
  state.saved_contents = saved_contents or {}
  state.user_prompt = user_prompt
  state.action = action
  state.instruction = instruction
  state.session_id = session_id

  -- 変更ファイル＆レスポンスチェック
  local has_files = modified_files and #modified_files > 0
  local has_response = response_text and response_text ~= ""

  -- 初期選択ファイルのインデックスを決定
  local initial_idx = 1
  if initial_file and has_files then
    -- 相対パスと絶対パスの両方で照合
    local normalized_initial = vim.fn.fnamemodify(initial_file, ":p")
    for i, file in ipairs(modified_files) do
      local normalized_file = vim.fn.fnamemodify(file, ":p")
      if normalized_file == normalized_initial then
        initial_idx = i
        break
      end
    end
  end

  -- ファイルがある場合のみインデックスを設定
  state.selected_file_idx = has_files and initial_idx or 0

  if mode == "inline" then
    -- Inline mode: ファイル変更またはレスポンスがあればプレビュー表示
    if not has_files and not has_response then
      vim.notify(
        "No files were modified and no response available. Nothing to preview.",
        vim.log.levels.INFO
      )
      return false
    end
  else
    -- Chat mode: ファイル変更が必須
    if not has_files then
      vim.notify(
        "No files were modified during this action. Nothing to preview.",
        vim.log.levels.INFO
      )
      return false
    end
  end

  -- Diff取得（ファイルがある場合のみ）
  if has_files then
    state.diffs = {}
    for _, file in ipairs(modified_files) do
      -- 保存された内容がある場合はそれと比較、ない場合は通常のgit diff
      state.diffs[file] = M._generate_diff_from_saved(file)
    end
  else
    state.diffs = {}
  end

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

---一時ファイルを使ってgit diff --no-indexを実行
---@param before_lines string[] 変更前の行
---@param after_lines string[] 変更後の行
---@param file_path string ファイルパス（エラーメッセージ用）
---@return table { lines: string[], has_delta: boolean, error: boolean? }
local function _generate_diff_with_temp_files(before_lines, after_lines, file_path)
  local tmp_before = vim.fn.tempname()
  local tmp_after = vim.fn.tempname()

  -- pcallでクリーンアップを保証
  local ok, result = pcall(function()
    -- 一時ファイルに書き出し
    vim.fn.writefile(before_lines, tmp_before)
    vim.fn.writefile(after_lines, tmp_after)

    -- git diff --no-index で差分を取得
    local cmd = string.format(
      "git diff --no-index --no-color %s %s",
      vim.fn.shellescape(tmp_before),
      vim.fn.shellescape(tmp_after)
    )

    local lines = vim.fn.systemlist({ "sh", "-c", cmd })

    -- エラーチェック（git diff --no-indexは差分がある場合exit code 1を返す）
    if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then
      error(string.format("git diff failed with exit code %d", vim.v.shell_error))
    end

    return lines
  end)

  -- 一時ファイルを必ずクリーンアップ
  vim.fn.delete(tmp_before)
  vim.fn.delete(tmp_after)

  -- エラーチェック
  if not ok then
    return {
      lines = {
        "Error: Could not generate diff for " .. file_path,
        "Details: " .. tostring(result),
      },
      has_delta = false,
      error = true,
    }
  end

  -- 差分がない場合
  if #result == 0 then
    return {
      lines = { "No changes detected for " .. file_path },
      has_delta = false,
      error = false,
    }
  end

  return {
    lines = result,
    has_delta = false,
    error = false,
  }
end

---保存された内容とファイルの差分を生成（git diff --no-index使用）
---@param file_path string ファイルパス
---@return table { lines: string[], has_delta: boolean, error: boolean? }
function M._generate_diff_from_saved(file_path)
  -- Check if this is a [Buffer N] identifier
  local is_buffer_id = BufferIdentifier.is_buffer_identifier(file_path)
  local normalized_path = BufferIdentifier.normalize_path(file_path)

  -- ファイルが実際に存在するかチェック
  local file_exists = not is_buffer_id and vim.fn.filereadable(normalized_path) == 1

  -- 新規バッファ（ファイルが存在しない）の場合
  if not file_exists then
    -- バッファ内容を取得
    local bufnr
    if is_buffer_id then
      -- Extract buffer number from [Buffer N] format
      bufnr = BufferIdentifier.extract_bufnr(file_path)
    else
      bufnr = vim.fn.bufnr(normalized_path)
    end

    -- バッファが見つからない、または無効な場合
    if not bufnr or bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
      return {
        lines = {
          "Error: Buffer not found or not loaded for " .. file_path,
        },
        has_delta = false,
        error = true,
      }
    end

    -- バッファ内容を安全に取得
    local ok, current_lines = pcall(vim.api.nvim_buf_get_lines, bufnr, 0, -1, false)
    if not ok then
      return {
        lines = {
          "Error: Failed to read buffer " .. file_path .. ": " .. tostring(current_lines),
        },
        has_delta = false,
        error = true,
      }
    end

    -- saved_contentsがある場合は、それと現在のバッファ内容を比較
    if state.saved_contents[normalized_path] then
      return _generate_diff_with_temp_files(state.saved_contents[normalized_path], current_lines, file_path)
    else
      -- saved_contentsがない場合は、全内容を新規追加として表示
      local diff_lines = {
        "diff --git a/" .. file_path .. " b/" .. file_path,
        "new file",
        "--- /dev/null",
        "+++ b/" .. file_path,
        "@@ -0,0 +1," .. #current_lines .. " @@",
      }

      for _, line in ipairs(current_lines) do
        table.insert(diff_lines, "+" .. line)
      end

      return {
        lines = diff_lines,
        has_delta = false,
        error = false,
      }
    end
  end

  -- ファイルが存在する場合の既存ロジック
  -- 保存された内容がない場合は通常のgit diffにフォールバック
  if not state.saved_contents[normalized_path] then
    return git.get_diff(file_path)
  end

  -- 現在のファイル内容を取得
  local current_lines = vim.fn.readfile(file_path)

  -- 保存された内容と現在の内容を比較
  return _generate_diff_with_temp_files(state.saved_contents[normalized_path], current_lines, file_path)
end

---ウィンドウレイアウトを作成
function M._create_layout()
  if state.mode == "inline" then
    M._create_inline_layout()
  else -- chat
    M._create_chat_layout()
  end
end

---インライン用レイアウト（アコーディオン式：Files左、Diff/Response右縦並び）
function M._create_inline_layout()
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  -- アコーディオン式レイアウト：Files左、Diff/Response右縦並び
  local files_width = math.floor(total_width * 0.25)  -- Files: 25%
  local right_width = total_width - files_width - 3  -- 右側パネル: 75%
  local collapsed_height = 1  -- 折りたたみ時の高さ（タイトル行のみ）

  -- active_panelに応じて高さを計算
  local diff_height, response_height
  if state.active_panel == "diff" then
    diff_height = total_height - collapsed_height - 2  -- Diff展開、Response折りたたみ
    response_height = collapsed_height
  else  -- "response"
    diff_height = collapsed_height  -- Diff折りたたみ、Response展開
    response_height = total_height - collapsed_height - 2
  end

  -- ファイルリストバッファ（左側、固定）
  state.buf_files = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf_files].bufhidden = "wipe"
  vim.bo[state.buf_files].modifiable = false

  state.win_files = vim.api.nvim_open_win(state.buf_files, true, {
    relative = "editor",
    width = files_width,
    height = total_height,
    row = start_row,
    col = start_col,
    style = "minimal",
    border = "rounded",
    title = " Files ",
    title_pos = "center",
  })

  -- Diffプレビューバッファ（右上）
  state.buf_diff = diff_util.create_diff_buffer({})
  local diff_title = state.active_panel == "diff" and " ▼ Diff " or " ▶ Diff "
  state.win_diff = vim.api.nvim_open_win(state.buf_diff, false, {
    relative = "editor",
    width = right_width,
    height = diff_height,
    row = start_row,
    col = start_col + files_width + 3,
    style = "minimal",
    border = "rounded",
    title = diff_title,
    title_pos = "center",
  })

  -- レスポンスバッファ（右下）
  state.buf_response = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf_response].bufhidden = "wipe"
  vim.bo[state.buf_response].modifiable = false
  vim.bo[state.buf_response].filetype = "markdown"

  local response_title = state.active_panel == "response" and " ▼ Response " or " ▶ Response "
  state.win_response = vim.api.nvim_open_win(state.buf_response, false, {
    relative = "editor",
    width = right_width,
    height = response_height,
    row = start_row + diff_height + 2,
    col = start_col + files_width + 3,
    style = "minimal",
    border = "rounded",
    title = response_title,
    title_pos = "center",
  })
end

---チャット用レイアウト（2パネル：Files, Diff）
function M._create_chat_layout()
  -- レスポンシブ判定（120列以上で横並び）
  local is_wide = vim.o.columns >= 120
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  if is_wide then
    -- 横並びレイアウト（2パネル：Files, Diff）
    local files_width = math.floor(total_width * 0.3)
    local diff_width = total_width - files_width - 3 -- 3 for borders

    -- ファイルリストバッファ
    state.buf_files = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_files, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

    state.win_files = vim.api.nvim_open_win(state.buf_files, true, {
      relative = "editor",
      width = files_width,
      height = total_height,
      row = start_row,
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
      height = total_height,
      row = start_row,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = " Diff Preview ",
      title_pos = "center",
    })
  else
    -- 縦並びレイアウト（120列未満、2パネル：Files, Diff）
    local files_height = 8
    local diff_height = total_height - files_height - 2

    -- ファイルリストバッファ
    state.buf_files = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(state.buf_files, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

    state.win_files = vim.api.nvim_open_win(state.buf_files, true, {
      relative = "editor",
      width = total_width,
      height = files_height,
      row = start_row,
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
      row = start_row + files_height + 2,
      col = start_col,
      style = "minimal",
      border = "rounded",
      title = " Diff Preview ",
      title_pos = "center",
    })
  end
end

---全パネルを再描画
function M._render_all()
  M._render_files_panel()
  M._render_diff_panel()
  if state.mode == "inline" then
    M._render_response_panel()
  end
end

---ファイルリストパネルを描画
function M._render_files_panel()
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local lines = { string.format("Files (%d):", #state.modified_files), "" }

  if #state.modified_files == 0 then
    table.insert(lines, "No files modified")
  else
    for i, file in ipairs(state.modified_files) do
      local marker = (i == state.selected_file_idx) and "▶ " or "  "
      table.insert(lines, marker .. file)
    end
  end

  -- Add separator and help text
  table.insert(lines, "")
  table.insert(lines, string.rep("─", 40))
  local help_start_idx = #lines  -- セパレーターの次の行のインデックス（0-indexed）
  table.insert(lines, "<CR> Select")
  table.insert(lines, "<Tab> Next")
  table.insert(lines, "<S-Tab> Prev")
  table.insert(lines, "a Accept")
  table.insert(lines, "r Reject")
  table.insert(lines, "q Quit")

  vim.bo[state.buf_files].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.buf_files, "modifiable", false)

  -- 選択行をハイライト
  local ns_id = vim.api.nvim_create_namespace("vibing_inline_preview")
  vim.api.nvim_buf_clear_namespace(state.buf_files, ns_id, 0, -1)
  if state.selected_file_idx > 0 and state.selected_file_idx <= #state.modified_files then
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Visual", state.selected_file_idx + 1, 0, -1)
  end

  -- Highlight help text
  for i = help_start_idx, #lines - 1 do
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Comment", i, 0, -1)
  end
end

---Diffパネルを描画
function M._render_diff_panel()
  if not state.buf_diff or not vim.api.nvim_buf_is_valid(state.buf_diff) then
    return
  end

  -- Inline modeで折りたたまれている場合は最小限の表示
  if state.mode == "inline" and state.active_panel ~= "diff" then
    diff_util.update_diff_buffer(state.buf_diff, { "Press Tab to expand Diff panel" })
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

  -- Inline modeで折りたたまれている場合は最小限の表示
  if state.mode == "inline" and state.active_panel ~= "response" then
    vim.bo[state.buf_response].modifiable = true
    vim.api.nvim_buf_set_lines(state.buf_response, 0, -1, false, { "Press Tab to expand Response panel" })
    vim.bo[state.buf_response].modifiable = false
    return
  end

  -- response_textを改行で分割して行配列に変換
  local response_lines = vim.split(state.response_text, "\n", { plain = true })
  local lines = {}
  table.insert(lines, "Response:")
  for _, line in ipairs(response_lines) do
    table.insert(lines, line)
  end

  vim.bo[state.buf_response].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_response, 0, -1, false, lines)
  vim.bo[state.buf_response].modifiable = false
end

---プレビューUIウィンドウ間を循環移動
---@param direction number 1で次、-1で前
function M._cycle_window(direction)
  local current_win = vim.api.nvim_get_current_win()

  -- プレビューUIウィンドウのリストを作成
  local wins = { state.win_files, state.win_diff }
  if state.mode == "inline" and state.win_response then
    table.insert(wins, state.win_response)
  end

  -- 現在のウィンドウのインデックスを検索
  local current_idx = nil
  for i, win in ipairs(wins) do
    if win == current_win then
      current_idx = i
      break
    end
  end

  -- プレビューUIウィンドウにいない場合は最初のウィンドウへ
  if not current_idx then
    if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      vim.api.nvim_set_current_win(wins[1])
    end
    return
  end

  -- 次のウィンドウへ移動
  local next_idx = current_idx + direction
  if next_idx > #wins then
    next_idx = 1
  elseif next_idx < 1 then
    next_idx = #wins
  end

  if wins[next_idx] and vim.api.nvim_win_is_valid(wins[next_idx]) then
    vim.api.nvim_set_current_win(wins[next_idx])
  end
end

---アコーディオンパネル切り替え（inline modeのみ）
---Diff ⇄ Response を切り替え、展開/折りたたみを制御
function M._switch_panel(target_panel)
  if state.mode ~= "inline" then
    return
  end

  -- 現在のウィンドウを取得
  local current_win = vim.api.nvim_get_current_win()

  -- すでに目的のパネルが展開されていて、かつそのパネルにフォーカスがある場合のみスキップ
  local target_win = target_panel == "diff" and state.win_diff or state.win_response
  if state.active_panel == target_panel and current_win == target_win then
    return
  end

  -- active_panelを切り替え
  state.active_panel = target_panel

  -- レイアウト再計算
  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.9)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)
  local files_width = math.floor(total_width * 0.25)
  local collapsed_height = 1

  local diff_height, response_height
  if state.active_panel == "diff" then
    diff_height = total_height - collapsed_height - 2
    response_height = collapsed_height
  else  -- "response"
    diff_height = collapsed_height
    response_height = total_height - collapsed_height - 2
  end

  -- Diffウィンドウの高さとタイトルを更新
  if state.win_diff and vim.api.nvim_win_is_valid(state.win_diff) then
    local diff_title = state.active_panel == "diff" and " ▼ Diff " or " ▶ Diff "
    vim.api.nvim_win_set_config(state.win_diff, {
      relative = "editor",
      width = total_width - files_width - 3,
      height = diff_height,
      row = start_row,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = diff_title,
      title_pos = "center",
    })
  end

  -- Responseウィンドウの高さとタイトルを更新
  if state.win_response and vim.api.nvim_win_is_valid(state.win_response) then
    local response_title = state.active_panel == "response" and " ▼ Response " or " ▶ Response "
    vim.api.nvim_win_set_config(state.win_response, {
      relative = "editor",
      width = total_width - files_width - 3,
      height = response_height,
      row = start_row + diff_height + 2,
      col = start_col + files_width + 3,
      style = "minimal",
      border = "rounded",
      title = response_title,
      title_pos = "center",
    })
  end

  -- 展開したパネルにフォーカスを移動
  local target_win = target_panel == "diff" and state.win_diff or state.win_response
  if target_win and vim.api.nvim_win_is_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
  end

  -- パネル再描画
  M._render_all()
end

---キーマップを設定
function M._setup_keymaps()
  -- バッファリストを収集
  local buffers = {}

  if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
    buffers.files = vim.api.nvim_win_get_buf(state.win_files)
  end
  if state.win_diff and vim.api.nvim_win_is_valid(state.win_diff) then
    buffers.diff = vim.api.nvim_win_get_buf(state.win_diff)
  end
  if state.mode == "inline" and state.win_response and vim.api.nvim_win_is_valid(state.win_response) then
    buffers.response = vim.api.nvim_win_get_buf(state.win_response)
  end

  -- 各バッファに対してキーマップを設定
  for buf_type, buf in pairs(buffers) do
    -- Enter: ファイル選択（Filesバッファのみ）
    if buf_type == "files" then
      vim.keymap.set("n", "<CR>", function()
        M._on_file_select_from_cursor()
      end, { buffer = buf, silent = true, desc = "Select file" })
    end

    -- 共通キーマップ: a/r/q/Esc/b
    vim.keymap.set("n", "a", M._on_accept, { buffer = buf, silent = true, desc = "Accept changes" })
    vim.keymap.set("n", "r", M._on_reject, { buffer = buf, silent = true, desc = "Reject changes" })
    vim.keymap.set("n", "q", M._on_quit, { buffer = buf, silent = true, desc = "Quit" })
    vim.keymap.set("n", "<Esc>", M._on_quit, { buffer = buf, silent = true, desc = "Quit" })
    vim.keymap.set("n", "b", M.save_as_vibing, { buffer = buf, silent = true, desc = "Save to buffer (vibing file)" })

    -- Tab/Shift-Tab
    if state.mode == "inline" then
      -- Inline mode: アコーディオン式パネル切り替え
      vim.keymap.set("n", "<Tab>", function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win == state.win_files then
          M._switch_panel("diff")
        elseif current_win == state.win_diff then
          M._switch_panel("response")
        elseif current_win == state.win_response then
          if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
            vim.api.nvim_set_current_win(state.win_files)
          end
        end
      end, { buffer = buf, silent = true, desc = "Next panel" })

      vim.keymap.set("n", "<S-Tab>", function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win == state.win_files then
          M._switch_panel("response")
        elseif current_win == state.win_response then
          M._switch_panel("diff")
        elseif current_win == state.win_diff then
          if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
            vim.api.nvim_set_current_win(state.win_files)
          end
        end
      end, { buffer = buf, silent = true, desc = "Previous panel" })
    else
      -- Chat mode: 従来のウィンドウ循環
      vim.keymap.set("n", "<Tab>", function()
        M._cycle_window(1)
      end, { buffer = buf, silent = true, desc = "Next window" })

      vim.keymap.set("n", "<S-Tab>", function()
        M._cycle_window(-1)
      end, { buffer = buf, silent = true, desc = "Previous window" })
    end
  end
end

---カーソル位置のファイルを選択
function M._on_file_select_from_cursor()
  if not state.win_files or not vim.api.nvim_win_is_valid(state.win_files) then
    return
  end

  -- カーソル位置を取得（1-indexed）
  local cursor = vim.api.nvim_win_get_cursor(state.win_files)
  local cursor_line = cursor[1]

  -- ファイルリストは3行目から開始（1行目: "Files (n):", 2行目: ""）
  local file_idx = cursor_line - 2

  -- 範囲チェック
  if file_idx < 1 or file_idx > #state.modified_files then
    return
  end

  state.selected_file_idx = file_idx

  -- 再描画
  M._render_files_panel()
  M._render_diff_panel()
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
end

---Accept処理（変更を保持）
function M._on_accept()
  M._close_all()
  if #state.modified_files == 0 then
    vim.notify("No files modified", vim.log.levels.INFO)
  else
    vim.notify(
      string.format("Accepted changes to %d files", #state.modified_files),
      vim.log.levels.INFO
    )
  end
end

---Reject処理（変更を元に戻す）
function M._on_reject()
  -- ファイルがない場合はスキップ
  if #state.modified_files == 0 then
    M._close_all()
    vim.notify("No files to revert", vim.log.levels.INFO)
    return
  end

  -- 保存された内容があるファイルとないファイルを分類
  local files_with_saved = {}
  local files_without_saved = {}

  for _, file in ipairs(state.modified_files) do
    -- Check if this is a [Buffer N] identifier
    local is_buffer_id = file:match("^%[Buffer %d+%]$")
    local normalized_path

    if is_buffer_id then
      -- Don't normalize buffer identifiers
      normalized_path = file
    else
      -- ファイルパスを正規化（絶対パス）
      normalized_path = vim.fn.fnamemodify(file, ":p")
    end

    if state.saved_contents[normalized_path] then
      table.insert(files_with_saved, file)
    else
      table.insert(files_without_saved, file)
    end
  end

  local reverted_files = {}
  local errors = {}

  -- 保存された内容で復元（Claude変更のみを巻き戻し）
  for _, file in ipairs(files_with_saved) do
    -- Check if this is a [Buffer N] identifier
    local is_buffer_id = file:match("^%[Buffer %d+%]$")
    local normalized_path

    if is_buffer_id then
      -- Don't normalize buffer identifiers
      normalized_path = file
    else
      normalized_path = vim.fn.fnamemodify(file, ":p")
    end

    local ok, err = pcall(function()
      if is_buffer_id then
        -- For unnamed buffers, write directly to the buffer
        local bufnr = tonumber(file:match("%[Buffer (%d+)%]"))
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, state.saved_contents[normalized_path])
        else
          error("Invalid buffer: " .. file)
        end
      else
        -- For named files, write to file
        vim.fn.writefile(state.saved_contents[normalized_path], file)
      end
    end)

    if ok then
      table.insert(reverted_files, file)
    else
      table.insert(errors, { file = file, message = tostring(err) })
    end
  end

  -- 保存された内容がないファイルはgit checkoutで復元（ユーザー変更も巻き戻る）
  -- ただし、[Buffer N]形式のファイルはgit checkoutの対象外
  if #files_without_saved > 0 then
    -- Filter out [Buffer N] identifiers from git checkout
    local git_files = {}
    for _, file in ipairs(files_without_saved) do
      local is_buffer_id = file:match("^%[Buffer %d+%]$")
      if not is_buffer_id then
        table.insert(git_files, file)
      else
        -- [Buffer N] without saved_contents is an error
        table.insert(errors, { file = file, message = "No saved content for unnamed buffer" })
      end
    end

    if #git_files > 0 then
      local result = git.checkout_files(git_files)

      if result.success then
        for _, file in ipairs(git_files) do
          table.insert(reverted_files, file)
        end
      else
        for _, err in ipairs(result.errors) do
          table.insert(errors, err)
        end
        for _, file in ipairs(git_files) do
          local found_error = false
          for _, err in ipairs(result.errors) do
            if err.file == file then
              found_error = true
              break
            end
          end
          if not found_error then
            table.insert(reverted_files, file)
          end
        end
      end
    end
  end

  -- 結果通知
  if #errors == 0 then
    vim.notify(
      string.format("Reverted %d files successfully", #reverted_files),
      vim.log.levels.INFO
    )
  else
    local success_count = #reverted_files
    local failed_count = #errors

    vim.notify(
      string.format("Reverted %d/%d files. %d failed.", success_count, #state.modified_files, failed_count),
      vim.log.levels.WARN
    )

    -- エラー詳細を表示
    for _, err in ipairs(errors) do
      vim.notify(string.format("  - %s: %s", err.file, err.message), vim.log.levels.ERROR)
    end
  end

  -- 成功したファイルのバッファをリロード
  if #reverted_files > 0 then
    BufferReload.reload_files(reverted_files)
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
  for _, win in ipairs({ state.win_files, state.win_diff, state.win_response }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  -- バッファを削除
  for _, buf in ipairs({ state.buf_files, state.buf_diff, state.buf_response }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- 状態をクリア
  state = {
    mode = "inline",
    modified_files = {},
    diffs = {},
    selected_file_idx = 1,
    response_text = "",
    active_panel = "diff",
    saved_contents = {},
    win_files = nil,
    win_diff = nil,
    win_response = nil,
    buf_files = nil,
    buf_diff = nil,
    buf_response = nil,
  }
end

---現在のプレビュー内容を.vibingファイルとして保存してChatBufferで開く
---inlineモードでのみ使用可能（user_prompt, response_textが必要）
---@return boolean success 成功した場合true
function M.save_as_vibing()
  -- inlineモードでのみ使用可能
  if state.mode ~= "inline" then
    vim.notify("Save as vibing is only available in inline mode", vim.log.levels.WARN)
    return false
  end

  -- 必要な情報をチェック
  if not state.user_prompt or state.user_prompt == "" then
    vim.notify("No user prompt available to save", vim.log.levels.WARN)
    return false
  end

  -- 保存先ディレクトリを作成
  local project_root = vim.fn.getcwd()
  local save_dir = project_root .. "/.vibing/inline/"
  vim.fn.mkdir(save_dir, "p")

  -- ファイル名を生成（日時ベース）
  local filename = os.date("inline-%Y%m%d-%H%M%S.vibing")
  local file_path = save_dir .. filename

  -- vibingファイルの内容を生成
  local lines = {}

  -- 設定を取得
  local vibing = require("vibing")
  local config = vibing.get_config()

  -- フロントマター（chatと同様）
  table.insert(lines, "---")
  table.insert(lines, "vibing.nvim: true")
  -- session_idを引き継ぐ（ない場合は~）
  if state.session_id and state.session_id ~= "" then
    table.insert(lines, "session_id: " .. state.session_id)
  else
    table.insert(lines, "session_id: ~")
  end
  table.insert(lines, "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"))
  table.insert(lines, "source: inline")

  -- アクション情報
  if state.action then
    table.insert(lines, "action: " .. state.action)
  end
  if state.instruction and state.instruction ~= "" then
    table.insert(lines, "instruction: " .. state.instruction)
  end

  -- agent設定（chatと同様）
  if config.agent then
    if config.agent.default_mode then
      table.insert(lines, "mode: " .. config.agent.default_mode)
    end
    if config.agent.default_model then
      table.insert(lines, "model: " .. config.agent.default_model)
    end
  end

  -- permissions設定（chatと同様）
  if config.permissions then
    if config.permissions.mode then
      table.insert(lines, "permission_mode: " .. config.permissions.mode)
    end
    if config.permissions.allow and #config.permissions.allow > 0 then
      table.insert(lines, "permissions_allow:")
      for _, tool in ipairs(config.permissions.allow) do
        table.insert(lines, "  - " .. tool)
      end
    end
    if config.permissions.deny and #config.permissions.deny > 0 then
      table.insert(lines, "permissions_deny:")
      for _, tool in ipairs(config.permissions.deny) do
        table.insert(lines, "  - " .. tool)
      end
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")

  -- タイトル
  table.insert(lines, "# Inline Action Result")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")

  -- ユーザーメッセージ
  table.insert(lines, Timestamp.create_header("User"))
  table.insert(lines, "")
  -- user_promptを行ごとに分割して追加
  if state.user_prompt and state.user_prompt ~= "" then
    for _, line in ipairs(vim.split(state.user_prompt, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  end
  table.insert(lines, "")

  -- アシスタント応答
  table.insert(lines, Timestamp.create_header("Assistant"))
  table.insert(lines, "")
  if state.response_text and state.response_text ~= "" then
    -- response_textを行ごとに分割して追加
    for _, line in ipairs(vim.split(state.response_text, "\n", { plain = true })) do
      table.insert(lines, line)
    end
  else
    table.insert(lines, "(No response)")
  end
  table.insert(lines, "")

  -- Modified Files セクション
  if #state.modified_files > 0 then
    table.insert(lines, "## Modified Files")
    table.insert(lines, "")
    for _, file in ipairs(state.modified_files) do
      local relative = vim.fn.fnamemodify(file, ":.")
      table.insert(lines, relative)
    end
    table.insert(lines, "")
  end

  -- User セクション（新規入力受付用）
  table.insert(lines, Timestamp.create_header("User"))
  table.insert(lines, "")

  -- ファイルに書き込み
  vim.fn.writefile(lines, file_path)

  -- ChatBufferで開く
  local ChatAction = require("vibing.actions.chat")
  ChatAction.open_file(file_path)

  vim.notify("Saved as " .. filename, vim.log.levels.INFO)

  -- プレビューUIを閉じる
  M._close_all()

  return true
end

return M
