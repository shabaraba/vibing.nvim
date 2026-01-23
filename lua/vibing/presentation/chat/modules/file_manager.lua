local M = {}

---一意なファイル名を生成
---@return string filename
function M.generate_unique_filename()
  local timestamp = os.date("%Y%m%d-%H%M%S")
  local hrtime = string.format("%016x", vim.loop.hrtime())
  local random_id = string.format("%04x", math.random(0, 65535))
  return string.format("chat-%s-%s-%s.vibing", timestamp, hrtime, random_id)
end

---プロジェクト固有のsystem-prompt.mdを初期化
---@param project_root string プロジェクトルート
local function ensure_system_prompt(project_root)
  local vibing_dir = project_root .. "/.vibing"
  local prompt_file = vibing_dir .. "/system-prompt.md"

  -- ファイルが存在しなければ空ファイルを作成
  if vim.fn.filereadable(prompt_file) == 0 then
    vim.fn.mkdir(vibing_dir, "p")
    vim.fn.writefile({}, prompt_file)
  end
end

---保存ディレクトリを取得
---@param config table 設定
---@return string directory_path
function M.get_save_directory(config)
  local location_type = config.save_location_type or "project"

  if location_type == "project" then
    local project_root = vim.fn.getcwd()
    ensure_system_prompt(project_root)
    return project_root .. "/.vibing/chat/"
  elseif location_type == "user" then
    return vim.fn.stdpath("data") .. "/vibing/chats/"
  elseif location_type == "custom" then
    local custom_path = config.save_dir
    if not custom_path:match("/$") then
      custom_path = custom_path .. "/"
    end
    return custom_path
  else
    local project_root = vim.fn.getcwd()
    ensure_system_prompt(project_root)
    return project_root .. "/.vibing/chat/"
  end
end

---ファイルからチャットを読み込む
---@param buf number バッファ番号
---@param file_path string ファイルパス
---@return boolean success
function M.load_from_file(buf, file_path)
  if not vim.fn.filereadable(file_path) then
    return false
  end

  local content = vim.fn.readfile(file_path)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  return true
end

---メッセージからファイル名を更新
---@param buf number バッファ番号
---@param current_path string? 現在のファイルパス
---@param message string メッセージ内容
---@return string? new_path 新しいファイルパス
function M.update_filename_from_message(buf, current_path, message)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end

  -- 既に意味のある名前の場合はスキップ
  if current_path and not current_path:match("chat_%d+_%d+") then
    return current_path
  end

  local filename_util = require("vibing.core.utils.filename")
  local base_filename = filename_util.generate_from_message(message)

  local project_root = vim.fn.getcwd()
  ensure_system_prompt(project_root)
  local chat_dir = project_root .. "/.vibing/chat/"
  vim.fn.mkdir(chat_dir, "p")

  local new_filename = base_filename .. ".vibing"
  local new_file_path = chat_dir .. new_filename

  -- 重複チェック
  local counter = 1
  while vim.fn.filereadable(new_file_path) == 1 do
    new_filename = base_filename .. "_" .. counter .. ".vibing"
    new_file_path = chat_dir .. new_filename
    counter = counter + 1
  end

  vim.api.nvim_buf_set_name(buf, new_file_path)
  return new_file_path
end

return M
