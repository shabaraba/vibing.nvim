---@class Vibing.UI.PatchViewer
---patchファイルの内容を2パネル構成（Files, Diff）で表示するビューア
local M = {}

local PatchStorage = require("vibing.infrastructure.storage.patch_storage")
local diff_util = require("vibing.core.utils.diff")

---@class Vibing.PatchViewer.State
---@field session_id string? セッションID
---@field patch_filename string? patchファイル名
---@field patch_content string? patch全体の内容
---@field files string[] patchに含まれるファイル一覧
---@field selected_idx number 選択中のファイルインデックス
---@field win_files number? ファイルリストウィンドウ
---@field win_diff number? Diffウィンドウ
---@field buf_files number? ファイルリストバッファ
---@field buf_diff number? Diffバッファ
local state = {
  session_id = nil,
  patch_filename = nil,
  patch_content = nil,
  files = {},
  selected_idx = 1,
  win_files = nil,
  win_diff = nil,
  buf_files = nil,
  buf_diff = nil,
}

---patchの内容を2パネル構成で表示
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@param target_file? string 初期選択するファイル（オプション）
function M.show(session_id, patch_filename, target_file)
  local patch_content = PatchStorage.read(session_id, patch_filename)

  if not patch_content or patch_content == "" then
    vim.notify("Patch file not found or empty", vim.log.levels.WARN)
    return
  end

  local files = M._extract_files_from_patch(patch_content)

  if #files == 0 then
    vim.notify("No files found in patch", vim.log.levels.WARN)
    return
  end

  -- 状態を初期化
  state.session_id = session_id
  state.patch_filename = patch_filename
  state.patch_content = patch_content
  state.files = files
  state.selected_idx = 1

  -- target_fileが指定されている場合、そのインデックスを探す
  if target_file then
    local normalized_target = vim.fn.fnamemodify(target_file, ":.")
    for i, file in ipairs(files) do
      if file == normalized_target or vim.fn.fnamemodify(file, ":.") == normalized_target then
        state.selected_idx = i
        break
      end
    end
  end

  -- UIを構築
  M._create_layout()
  M._render_all()
  M._setup_keymaps()
end

---patchからファイル一覧を抽出
---@param patch_content string patch内容
---@return string[] files ファイル一覧
function M._extract_files_from_patch(patch_content)
  local files = {}
  local seen = {}
  local cwd = vim.fn.getcwd()
  -- cwdから先頭の/を除去したもの（git diff --no-indexの出力形式に対応）
  local cwd_without_slash = cwd:sub(2)

  for line in patch_content:gmatch("[^\r\n]+") do
    -- diff --git a/path b/path 形式
    local file = line:match("^diff %-%-git a/(.+) b/")
    if file then
      -- git diff --no-index の出力形式: a/Users/... (先頭/なしの絶対パス風)
      -- cwdを含む場合は相対パスに変換
      if file:find(cwd_without_slash, 1, true) then
        local start_pos = file:find(cwd_without_slash, 1, true)
        file = file:sub(start_pos + #cwd_without_slash + 1) -- +1 for trailing slash
      elseif file:sub(1, 1) == "/" and file:find(cwd, 1, true) then
        -- /Users/.../project/lua/file.lua -> lua/file.lua
        file = file:sub(#cwd + 2)
      end

      if not seen[file] then
        seen[file] = true
        table.insert(files, file)
      end
    end
  end

  return files
end

---レイアウトを作成（2パネル: Files左、Diff右）
function M._create_layout()
  -- 既存のウィンドウがあれば閉じる（stateはリセットしない）
  M._close_windows_only()

  local total_width = math.floor(vim.o.columns * 0.9)
  local total_height = math.floor(vim.o.lines * 0.8)
  local start_row = math.floor((vim.o.lines - total_height) / 2)
  local start_col = math.floor((vim.o.columns - total_width) / 2)

  local files_width = math.floor(total_width * 0.3)
  local diff_width = total_width - files_width - 3

  -- ファイルリストバッファ
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

  -- Diffバッファ
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
end

---全パネルを描画
function M._render_all()
  M._render_files_panel()
  M._render_diff_panel()
end

---ファイルリストパネルを描画
function M._render_files_panel()
  if not state.buf_files or not vim.api.nvim_buf_is_valid(state.buf_files) then
    return
  end

  local lines = { string.format("Files (%d):", #state.files), "" }

  for i, file in ipairs(state.files) do
    local marker = (i == state.selected_idx) and "▶ " or "  "
    table.insert(lines, marker .. file)
  end

  -- ヘルプ
  table.insert(lines, "")
  table.insert(lines, string.rep("─", 30))
  local help_start = #lines
  table.insert(lines, "j/k  Navigate")
  table.insert(lines, "<CR> Select")
  table.insert(lines, "r    Revert patch")
  table.insert(lines, "q    Quit")

  vim.bo[state.buf_files].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf_files, 0, -1, false, lines)
  vim.bo[state.buf_files].modifiable = false

  -- ハイライト
  local ns_id = vim.api.nvim_create_namespace("vibing_patch_viewer")
  vim.api.nvim_buf_clear_namespace(state.buf_files, ns_id, 0, -1)

  -- 選択行をハイライト
  if state.selected_idx > 0 and state.selected_idx <= #state.files then
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Visual", state.selected_idx + 1, 0, -1)
  end

  -- ヘルプ行をコメント色に
  for i = help_start, #lines - 1 do
    vim.api.nvim_buf_add_highlight(state.buf_files, ns_id, "Comment", i, 0, -1)
  end
end

---Diffパネルを描画
function M._render_diff_panel()
  if not state.buf_diff or not vim.api.nvim_buf_is_valid(state.buf_diff) then
    return
  end

  if #state.files == 0 then
    diff_util.update_diff_buffer(state.buf_diff, { "No files in patch" })
    return
  end

  local file = state.files[state.selected_idx]
  local file_diff = M.extract_file_diff(state.patch_content, file)

  if not file_diff or file_diff == "" then
    diff_util.update_diff_buffer(state.buf_diff, { "No changes for " .. file })
    return
  end

  local diff_lines = vim.split(file_diff, "\n", { plain = true })
  diff_util.update_diff_buffer(state.buf_diff, diff_lines)
end

---キーマップを設定
function M._setup_keymaps()
  local buffers = { state.buf_files, state.buf_diff }

  for _, buf in ipairs(buffers) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      local opts = { buffer = buf, noremap = true, silent = true }

      -- ナビゲーション
      vim.keymap.set("n", "j", function()
        M._select_file(1)
      end, vim.tbl_extend("force", opts, { desc = "Next file" }))

      vim.keymap.set("n", "k", function()
        M._select_file(-1)
      end, vim.tbl_extend("force", opts, { desc = "Previous file" }))

      vim.keymap.set("n", "<CR>", function()
        M._select_file_from_cursor()
      end, vim.tbl_extend("force", opts, { desc = "Select file" }))

      -- Tab/Shift-Tabでウィンドウ切り替え
      vim.keymap.set("n", "<Tab>", function()
        M._cycle_window(1)
      end, vim.tbl_extend("force", opts, { desc = "Next window" }))

      vim.keymap.set("n", "<S-Tab>", function()
        M._cycle_window(-1)
      end, vim.tbl_extend("force", opts, { desc = "Previous window" }))

      -- Revert
      vim.keymap.set("n", "r", function()
        M._on_revert()
      end, vim.tbl_extend("force", opts, { desc = "Revert patch" }))

      -- 閉じる
      vim.keymap.set("n", "q", function()
        M._close()
      end, vim.tbl_extend("force", opts, { desc = "Close" }))

      vim.keymap.set("n", "<Esc>", function()
        M._close()
      end, vim.tbl_extend("force", opts, { desc = "Close" }))
    end
  end
end

---ファイル選択を変更
---@param direction number 1で次、-1で前
function M._select_file(direction)
  local new_idx = state.selected_idx + direction

  if new_idx < 1 then
    new_idx = #state.files
  elseif new_idx > #state.files then
    new_idx = 1
  end

  state.selected_idx = new_idx
  M._render_all()
end

---カーソル位置のファイルを選択
function M._select_file_from_cursor()
  if not state.win_files or not vim.api.nvim_win_is_valid(state.win_files) then
    return
  end

  local cursor = vim.api.nvim_win_get_cursor(state.win_files)
  local cursor_line = cursor[1]

  -- ファイルリストは3行目から開始
  local file_idx = cursor_line - 2

  if file_idx >= 1 and file_idx <= #state.files then
    state.selected_idx = file_idx
    M._render_all()
  end
end

---ウィンドウ間を循環移動
---@param direction number 1で次、-1で前
function M._cycle_window(direction)
  local wins = { state.win_files, state.win_diff }
  local current_win = vim.api.nvim_get_current_win()

  local current_idx = nil
  for i, win in ipairs(wins) do
    if win == current_win then
      current_idx = i
      break
    end
  end

  if not current_idx then
    if wins[1] and vim.api.nvim_win_is_valid(wins[1]) then
      vim.api.nvim_set_current_win(wins[1])
    end
    return
  end

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

---Revert処理
function M._on_revert()
  if not state.session_id or not state.patch_filename then
    vim.notify("No patch to revert", vim.log.levels.WARN)
    return
  end

  local success = M.revert(state.session_id, state.patch_filename)
  if success then
    M._close()
  end
end

---ウィンドウとバッファのみを閉じる（stateはリセットしない）
function M._close_windows_only()
  for _, win in ipairs({ state.win_files, state.win_diff }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  for _, buf in ipairs({ state.buf_files, state.buf_diff }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  state.win_files = nil
  state.win_diff = nil
  state.buf_files = nil
  state.buf_diff = nil
end

---ウィンドウを閉じる（stateも完全リセット）
function M._close()
  M._close_windows_only()

  state = {
    session_id = nil,
    patch_filename = nil,
    patch_content = nil,
    files = {},
    selected_idx = 1,
    win_files = nil,
    win_diff = nil,
    buf_files = nil,
    buf_diff = nil,
  }
end

---patchから特定のファイルのdiffを抽出
---@param patch_content string patch全体の内容
---@param target_file string 抽出したいファイルのパス
---@return string? file_diff ファイルのdiff部分
function M.extract_file_diff(patch_content, target_file)
  local lines = vim.split(patch_content, "\n", { plain = true })
  local result = {}
  local in_target_file = false
  local target_normalized = vim.fn.fnamemodify(target_file, ":.")
  local cwd = vim.fn.getcwd()
  local cwd_without_slash = cwd:sub(2)

  for _, line in ipairs(lines) do
    -- diff --git a/path b/path の行を探す
    local diff_file = line:match("^diff %-%-git a/(.+) b/")
    if diff_file then
      -- git diff --no-index の出力形式に対応
      local diff_normalized = diff_file
      if diff_file:find(cwd_without_slash, 1, true) then
        local start_pos = diff_file:find(cwd_without_slash, 1, true)
        diff_normalized = diff_file:sub(start_pos + #cwd_without_slash + 1)
      elseif diff_file:sub(1, 1) == "/" and diff_file:find(cwd, 1, true) then
        diff_normalized = diff_file:sub(#cwd + 2)
      else
        diff_normalized = vim.fn.fnamemodify(diff_file, ":.")
      end

      if diff_normalized == target_normalized or diff_file == target_file then
        in_target_file = true
        table.insert(result, line)
      else
        in_target_file = false
      end
    elseif in_target_file then
      table.insert(result, line)
    end
  end

  if #result == 0 then
    return nil
  end

  return table.concat(result, "\n")
end

---patchを逆適用（revert）
---@param session_id string セッションID
---@param patch_filename string patchファイル名
---@return boolean success
function M.revert(session_id, patch_filename)
  local success = PatchStorage.revert(session_id, patch_filename)

  if success then
    vim.notify("Patch reverted successfully", vim.log.levels.INFO)
    -- 変更されたファイルをリロード
    vim.cmd("checktime")
  else
    vim.notify("Failed to revert patch", vim.log.levels.ERROR)
  end

  return success
end

return M
