local notify = require("vibing.core.utils.notify")
local title_generator = require("vibing.core.utils.title_generator")
local filename_util = require("vibing.core.utils.filename")

---@param file_path string?
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

---@param dir string
---@return string
local function ensure_trailing_slash(dir)
  if dir:sub(-1) ~= "/" then
    return dir .. "/"
  end
  return dir
end

---@param dir string
---@param base_filename string
---@return string
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

---@param _ string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
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

  title_generator.generate_from_conversation(conversation, function(title, err)
    if err then
      notify.error(string.format("Failed to generate title: %s", err))
      return
    end

    if not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
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
        notify.error(string.format("Failed to save: %s", save_err))
        return
      end

      local rename_result = vim.fn.rename(old_file_path, new_file_path)
      if rename_result ~= 0 then
        notify.error("Failed to rename file")
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
        notify.error(string.format("Failed to save: %s", save_err))
        return
      end
    end

    local relative_path = vim.fn.fnamemodify(new_file_path, ":.")
    notify.info(string.format("Renamed to: %s", relative_path))
  end)

  return true
end
