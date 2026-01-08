local notify = require("vibing.core.utils.notify")

---@class Vibing.OilIntegration
---oil.nvim統合モジュール
---ファイラーからチャットへのファイルメンション追加機能を提供
local M = {}

---oil.nvimプラグインが利用可能かチェック
---pcallでrequire("oil")を試行し、読み込み成功時のみtrue
---@return boolean oil.nvimがインストールされている場合true
function M.is_available()
  return pcall(require, "oil")
end

---現在のバッファがoil.nvimバッファかチェック
---oil.get_current_dir()がnilでない場合はoil.nvimバッファと判定
---@return boolean oil.nvimバッファの場合true
function M.is_oil_buffer()
  if not M.is_available() then
    return false
  end

  local oil = require("oil")
  local current_dir = oil.get_current_dir()
  return current_dir ~= nil
end

---カーソル位置のエントリのファイルパスを取得
---ディレクトリの場合はnilを返す（ファイルのみ対象）
---現在のディレクトリパスとエントリ名を結合して絶対パスを生成
---@return string? カーソル位置のファイルの絶対パス、ディレクトリまたはエントリなしの場合はnil
function M.get_cursor_file()
  if not M.is_oil_buffer() then
    return nil
  end

  local oil = require("oil")
  local entry = oil.get_cursor_entry()

  if not entry then
    return nil
  end

  -- ディレクトリの場合はスキップ
  if entry.type == "directory" then
    return nil
  end

  local dir = oil.get_current_dir()
  if not dir then
    return nil
  end

  -- パスを結合（末尾のスラッシュを考慮）
  local file_path = dir
  if not file_path:match("/$") then
    file_path = file_path .. "/"
  end
  file_path = file_path .. entry.name

  return file_path
end

---選択されたファイルパスを取得
---Visual modeでの範囲選択に対応
---@param start_line number? 開始行（1-indexed）
---@param end_line number? 終了行（1-indexed）
---@return string[] 選択されたファイルの絶対パス配列（ファイルがない場合は空配列）
function M.get_selected_files(start_line, end_line)
  if not M.is_oil_buffer() then
    return {}
  end

  local oil = require("oil")
  local dir = oil.get_current_dir()
  if not dir then
    return {}
  end

  -- 範囲選択がない場合はカーソル位置のファイルのみ
  if not start_line or not end_line then
    local file = M.get_cursor_file()
    if file then
      return { file }
    end
    return {}
  end

  -- 範囲選択されている場合、その範囲のすべてのファイルを取得
  local files = {}
  local buf = vim.api.nvim_get_current_buf()

  -- oil.get_entry_on_line() APIを使用してエントリを取得
  for line_nr = start_line, end_line do
    local entry = oil.get_entry_on_line(buf, line_nr)
    if entry and entry.name and entry.type ~= "directory" then
      local file_path = dir
      if not file_path:match("/$") then
        file_path = file_path .. "/"
      end
      file_path = file_path .. entry.name
      table.insert(files, file_path)
    end
  end

  -- デバッグ: 結果が空の場合、少なくともカーソル位置のファイルを返す
  if #files == 0 then
    local file = M.get_cursor_file()
    if file then
      return { file }
    end
  end

  return files
end

---カーソル位置のファイルをチャットに@file:path形式で追加
---チャットが開いていない場合は自動的に開く
---相対パス変換と存在チェックを実施
---挿入後にカーソルを挿入位置に移動
function M.send_to_chat()
  if not M.is_oil_buffer() then
    notify.warn("Not in an oil.nvim buffer")
    return
  end

  local files = M.get_selected_files()

  if #files == 0 then
    notify.warn("No file selected (directories are not supported)")
    return
  end

  -- チャットバッファを取得または作成
  local chat = require("vibing.application.chat.use_case")
  if not chat.chat_buffer or not chat.chat_buffer:is_open() then
    chat.open()
  end

  -- カーソル位置を取得
  local buf = chat.chat_buffer:get_buffer()
  if not buf then
    notify.error("Failed to get chat buffer")
    return
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local insert_line = #lines

  -- ファイルパスを@file:path形式で挿入
  local cwd = vim.fn.getcwd():gsub("/$", "")
  local added_count = 0

  for _, file_path in ipairs(files) do
    -- ファイルが存在するか確認
    if vim.fn.filereadable(file_path) ~= 1 then
      vim.notify("[vibing] File not readable: " .. file_path, vim.log.levels.WARN)
      goto continue
    end

    -- 相対パスに変換
    local relative_path = file_path
    if file_path:sub(1, #cwd + 1) == cwd .. "/" then
      relative_path = file_path:sub(#cwd + 2)
    end

    local file_mention = "@file:" .. relative_path
    vim.api.nvim_buf_set_lines(buf, insert_line, insert_line, false, { file_mention })
    insert_line = insert_line + 1
    added_count = added_count + 1

    ::continue::
  end

  -- カーソルを挿入位置に移動
  if chat.chat_buffer:is_open() and chat.chat_buffer.win then
    pcall(vim.api.nvim_win_set_cursor, chat.chat_buffer.win, { insert_line, 0 })
  end

  notify.info(string.format("Added %d file(s) to chat", added_count))
end

return M
