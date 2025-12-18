---@class Vibing.ContextMigrator
---チャットファイルフォーマット移行モジュール
---古いフォーマット（Context行が上部）から新フォーマット（Context行が末尾）への移行を提供
local M = {}

---古いフォーマット（Contextが上部）を検出
---YAMLフロントマター後から最初の## Userまでの間にContext:行が存在するかチェック
---新フォーマットはContext行が末尾に配置される
---@param file_path string チャットファイルの絶対パス
---@return boolean フロントマター直後にContext行がある場合true（古いフォーマット）、それ以外はfalse
function M.detect_old_format(file_path)
  if vim.fn.filereadable(file_path) ~= 1 then
    return false
  end

  local lines = vim.fn.readfile(file_path)
  local in_frontmatter = false
  local frontmatter_end = 0

  -- フロントマター終了位置を見つける
  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      frontmatter_end = i
      break
    end
  end

  -- フロントマター後から最初の## Userまでの間にContext行があるか
  for i = frontmatter_end + 1, #lines do
    local line = lines[i]
    if line:match("^## User") then
      break
    end
    if line:match("^Context:") then
      return true  -- 古いフォーマット
    end
  end

  return false
end

---チャットファイルをマイグレーション
---古いフォーマット（Context行が上部）から新フォーマット（Context行が末尾）に変換
---処理フロー: フロントマター終了位置検出 → Context行抽出 → 末尾空行削除 → Context行を末尾に追加
---create_backupがtrueの場合は元ファイルの.bakバックアップを作成
---@param file_path string マイグレーション対象ファイルの絶対パス
---@param create_backup boolean バックアップ作成フラグ（trueで.bakファイル作成）
---@return boolean success マイグレーション成功時true、失敗時false
---@return string? error_message 失敗時のエラーメッセージ（成功時はnil）
function M.migrate_file(file_path, create_backup)
  if vim.fn.filereadable(file_path) ~= 1 then
    return false, "File not readable: " .. file_path
  end

  local lines = vim.fn.readfile(file_path)
  local new_lines = {}
  local context_line = nil
  local in_frontmatter = false
  local frontmatter_end = 0

  -- Step 1: フロントマター終了位置を見つける
  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      frontmatter_end = i
      break
    end
  end

  -- Step 2: Context行を抽出し、それ以外をnew_linesに追加
  for i, line in ipairs(lines) do
    if i <= frontmatter_end then
      table.insert(new_lines, line)
    elseif line:match("^Context:") and not context_line then
      context_line = line
      -- Context行は追加しない（後で末尾に追加）
    else
      table.insert(new_lines, line)
    end
  end

  -- Step 3: 末尾の空行を削除
  while #new_lines > 0 and new_lines[#new_lines] == "" do
    table.remove(new_lines)
  end

  -- Step 4: Context行を末尾に追加
  if context_line then
    table.insert(new_lines, "")
    table.insert(new_lines, context_line)
  end

  -- Step 5: バックアップ作成
  if create_backup then
    local backup_path = file_path .. ".bak"
    local backup_result = vim.fn.writefile(lines, backup_path)
    if backup_result ~= 0 then
      return false, "Failed to create backup: " .. backup_path
    end
  end

  -- Step 6: 新フォーマットで保存
  local write_result = vim.fn.writefile(new_lines, file_path)
  if write_result ~= 0 then
    return false, "Failed to write migrated file: " .. file_path
  end

  return true, nil
end

---指定ディレクトリ内のマイグレーション対象ファイルをスキャン
---ディレクトリ内の全.mdファイルを再帰的に検索し、古いフォーマットのファイルのみを抽出
---:VibingMigrate --scanコマンドから呼び出され、一括マイグレーション対象を特定
---@param directory string スキャン対象ディレクトリの絶対パス（例: ".vibing/chat"）
---@return string[] file_paths 古いフォーマットのファイルパス配列（空配列の場合もあり）
function M.scan_chat_directory(directory)
  if vim.fn.isdirectory(directory) ~= 1 then
    return {}
  end

  local pattern = directory .. "/**/*.md"
  local files = vim.fn.glob(pattern, false, true)
  local old_format_files = {}

  for _, file in ipairs(files) do
    if M.detect_old_format(file) then
      table.insert(old_format_files, file)
    end
  end

  return old_format_files
end

---現在のチャットバッファをマイグレーション（開いているファイル用）
---:VibingMigrateコマンドで引数なし実行時に呼び出される
---開いているチャットバッファのfile_pathを使用してmigrate_file()を呼び出す
---自動的にバックアップ作成（create_backup=true）
---@param chat_buffer Vibing.ChatBuffer 現在開いているチャットバッファ
---@return boolean success マイグレーション成功時true、失敗時false
---@return string? error_message 失敗時のエラーメッセージ（成功時はnil）
function M.migrate_current_buffer(chat_buffer)
  if not chat_buffer.file_path then
    return false, "No file path associated with current buffer"
  end

  return M.migrate_file(chat_buffer.file_path, true)
end

return M
