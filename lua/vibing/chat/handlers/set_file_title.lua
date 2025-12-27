local notify = require("vibing.utils.notify")
local title_generator = require("vibing.utils.title_generator")
local filename_util = require("vibing.utils.filename")
local StatusManager = require("vibing.status_manager")

---現在のファイル名からファイルタイプ（chat/inline）を判定
---@param file_path string? 現在のファイルパス
---@return "chat"|"inline"
local function detect_file_type(file_path)
  if not file_path then
    return "chat"
  end

  local basename = vim.fn.fnamemodify(file_path, ":t")
  if basename:match("^inline") then
    return "inline"
  end
  return "chat"
end

---ディレクトリパスの末尾にスラッシュを付与
---@param dir string ディレクトリパス
---@return string normalized_dir 末尾スラッシュ付きのパス
local function ensure_trailing_slash(dir)
  if dir:sub(-1) ~= "/" then
    return dir .. "/"
  end
  return dir
end

---重複しないファイルパスを生成
---@param dir string ディレクトリパス
---@param base_filename string ベースファイル名（拡張子付き）
---@return string unique_path 一意なファイルパス
local function get_unique_file_path(dir, base_filename)
  dir = ensure_trailing_slash(dir)
  local new_path = dir .. base_filename

  if vim.fn.filereadable(new_path) == 0 then
    return new_path
  end

  local name_without_ext = base_filename:gsub("%.vibing$", "")
  local counter = 1

  while vim.fn.filereadable(new_path) == 1 do
    local new_filename = string.format("%s_%d.vibing", name_without_ext, counter)
    new_path = dir .. new_filename
    counter = counter + 1
  end

  return new_path
end

---:VibingSetFileTitleコマンドハンドラー
---チャット内容からAIにタイトルを生成させ、ファイル名を変更
---vim.fn.rename()でアトミックにリネーム
---@param _ string[] コマンド引数（このハンドラーでは未使用）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean リクエストを送信した場合true
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return false
  end

  local conversation = chat_buffer:extract_conversation()
  if #conversation == 0 then
    notify.warn("No conversation to generate title from")
    return false
  end

  local old_file_path = chat_buffer.file_path
  local file_type = detect_file_type(old_file_path)
  local save_dir = chat_buffer:_get_save_directory()

  local vibing = require("vibing")
  local config = vibing.get_config()
  local status_mgr = StatusManager:new(config.status)
  status_mgr:set_thinking("chat")

  title_generator.generate_from_conversation(conversation, function(title, err)
    if err then
      status_mgr:set_error(string.format("Failed to generate title: %s", err))
      return
    end

    if not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
      status_mgr:clear()
      notify.warn("Buffer was closed before title generation completed")
      return
    end

    local new_filename = filename_util.generate_with_title(title, file_type)
    local normalized_dir = ensure_trailing_slash(save_dir)

    if vim.fn.isdirectory(normalized_dir) == 0 then
      vim.fn.mkdir(normalized_dir, "p")
    end

    local new_file_path = get_unique_file_path(save_dir, new_filename)

    if old_file_path and vim.fn.filereadable(old_file_path) == 1 then
      local ok, save_err = pcall(function()
        vim.api.nvim_buf_call(chat_buffer.buf, function()
          vim.cmd("write")
        end)
      end)

      if not ok then
        status_mgr:set_error(string.format("Failed to save: %s", save_err))
        return
      end

      local rename_result = vim.fn.rename(old_file_path, new_file_path)
      if rename_result ~= 0 then
        status_mgr:set_error("Failed to rename file")
        return
      end

      vim.api.nvim_buf_set_name(chat_buffer.buf, new_file_path)
      chat_buffer.file_path = new_file_path
    else
      chat_buffer.file_path = new_file_path
      vim.api.nvim_buf_set_name(chat_buffer.buf, new_file_path)

      local ok, save_err = pcall(function()
        vim.api.nvim_buf_call(chat_buffer.buf, function()
          vim.cmd("write")
        end)
      end)

      if not ok then
        status_mgr:set_error(string.format("Failed to save: %s", save_err))
        return
      end
    end

    status_mgr:set_done()
    local relative_path = vim.fn.fnamemodify(new_file_path, ":.")
    notify.info(string.format("Renamed to: %s", relative_path))
  end)

  return true
end
