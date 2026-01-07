local Context = require("vibing.context")

local M = {}

---キーマップを設定
---@param buf number バッファ番号
---@param callbacks table コールバック関数テーブル
---@param keymaps table キーマップ設定
function M.setup(buf, callbacks, keymaps)
  local function set_keymaps()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    pcall(vim.keymap.del, "n", keymaps.send, { buffer = buf })

    vim.keymap.set("n", keymaps.send, function()
      if callbacks.send_message then
        callbacks.send_message()
      end
    end, { buffer = buf, desc = "Send message" })

    vim.keymap.set("n", keymaps.cancel, function()
      if callbacks.cancel then
        callbacks.cancel()
      end
    end, { buffer = buf, desc = "Cancel request" })

    vim.keymap.set("n", keymaps.add_context, function()
      vim.ui.input({ prompt = "Add context: ", completion = "file" }, function(path)
        if path then
          Context.add(path)
          if callbacks.update_context_line then
            callbacks.update_context_line()
          end
        end
      end)
    end, { buffer = buf, desc = "Add context" })

    vim.keymap.set("n", keymaps.open_diff, function()
      local FilePath = require("vibing.core.utils.file_path")
      local BufferIdentifier = require("vibing.core.utils.buffer_identifier")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        local modified_files = callbacks.get_modified_files and callbacks.get_modified_files()
        if modified_files and #modified_files > 0 then
          local normalized_cursor = BufferIdentifier.normalize_path(file_path)

          for _, mf in ipairs(modified_files) do
            local normalized_mf = BufferIdentifier.normalize_path(mf)

            if normalized_mf == normalized_cursor then
              local InlinePreview = require("vibing.ui.inline_preview")
              local saved_contents = callbacks.get_saved_contents and callbacks.get_saved_contents()
              InlinePreview.setup("chat", modified_files, "", saved_contents, file_path)
              return
            end
          end
        end

        local GitDiff = require("vibing.core.utils.git_diff")
        GitDiff.show_diff(file_path)
      end
    end, { buffer = buf, desc = "Open diff for file under cursor" })

    vim.keymap.set("n", keymaps.open_file, function()
      local FilePath = require("vibing.core.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        FilePath.open_file(file_path)
      end
    end, { buffer = buf, desc = "Open file under cursor" })

    vim.keymap.set("n", "gp", function()
      local modified_files = callbacks.get_modified_files and callbacks.get_modified_files()
      if not modified_files or #modified_files == 0 then
        vim.notify("No modified files to preview", vim.log.levels.WARN)
        return
      end

      local InlinePreview = require("vibing.ui.inline_preview")
      local saved_contents = callbacks.get_saved_contents and callbacks.get_saved_contents()
      InlinePreview.setup("chat", modified_files, "", saved_contents)
    end, { buffer = buf, desc = "Preview all modified files" })

    vim.keymap.set("n", "q", function()
      if callbacks.close then
        callbacks.close()
      end
    end, { buffer = buf, desc = "Close chat" })
  end

  set_keymaps()
  vim.defer_fn(set_keymaps, 100)

  local group = vim.api.nvim_create_augroup("vibing_chat_keymaps_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.defer_fn(set_keymaps, 10)
    end,
  })
end

return M
