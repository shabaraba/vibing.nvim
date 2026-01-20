local Context = require("vibing.application.context.manager")

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
      local PatchFinder = require("vibing.presentation.chat.modules.patch_finder")
      local PatchViewer = require("vibing.ui.patch_viewer")

      local file_path = FilePath.is_cursor_on_file_path(buf)
      if not file_path then
        vim.notify("No file path under cursor", vim.log.levels.INFO)
        return
      end

      -- patchファイル方式で表示を試みる
      local session_id = PatchFinder.get_session_id(buf)
      local patch_filename = PatchFinder.find_nearest_patch(buf)

      if session_id and patch_filename then
        -- patchファイルから該当ファイルのdiffを表示
        PatchViewer.show(session_id, patch_filename, file_path)
      else
        -- patchがない場合は設定に基づいてdiffツールを選択
        -- session_idを渡してセッション専用のmote storageを使用
        local DiffSelector = require("vibing.core.utils.diff_selector")
        DiffSelector.show_diff(file_path, session_id)
      end
    end, { buffer = buf, desc = "Open diff for file under cursor" })

    vim.keymap.set("n", keymaps.open_file, function()
      local FilePath = require("vibing.core.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        FilePath.open_file(file_path)
      end
    end, { buffer = buf, desc = "Open file under cursor" })

    -- NOTE: gp (preview all) was removed - use gd on individual files in Modified Files section
    -- Diff display now uses patch files in .vibing/patches/<session_id>/

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
