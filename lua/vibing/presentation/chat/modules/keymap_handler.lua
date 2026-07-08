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
      local view = require("vibing.presentation.chat.view")

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
        -- cwdをfrontmatterのworking_dirから取得
        local cwd = nil
        local chat_buf = view.get_chat_buffer(buf)
        if chat_buf then
          cwd = chat_buf:get_cwd()
        end
        DiffSelector.show_diff(file_path, session_id, cwd)
      end
    end, { buffer = buf, desc = "Open diff for file under cursor" })

    vim.keymap.set("n", keymaps.open_file, function()
      local FilePath = require("vibing.core.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        FilePath.open_file(file_path)
      else
        -- Modified Files セクション外では <cfile> で検出したパスを使う
        local cfile = vim.fn.expand("<cfile>")
        if cfile ~= "" then
          local expanded = vim.fn.expand(cfile)
          if vim.fn.filereadable(expanded) == 1 then
            FilePath.open_file(expanded)
          end
        end
      end
    end, { buffer = buf, desc = "Open file under cursor" })

    vim.keymap.set("n", keymaps.open_url, function()
      if not vim.ui.open then
        vim.notify("vim.ui.open requires Neovim 0.10+", vim.log.levels.WARN)
        return
      end
      -- バッファ行全体を取得（ソフト折り返し時も完全なURLを取得できる）
      local line = vim.fn.getline(".")
      local col = vim.api.nvim_win_get_cursor(0)[2] + 1 -- 1-indexed

      local url_pat = "(https?://[^ \t\n%]%)>\"']+)"
      local found_url = nil
      local best_dist = math.huge
      local max_dist = 10

      local search_pos = 1
      while true do
        local url_start, url_end, url = line:find(url_pat, search_pos)
        if not url_start then
          break
        end
        -- 末尾の句読点を除去
        url = url:gsub("[.,;:!?]+$", "")
        url_end = url_start + #url - 1

        if col >= url_start and col <= url_end then
          found_url = url
          break
        end
        local dist = math.min(math.abs(col - url_start), math.abs(col - url_end))
        if dist < best_dist and dist <= max_dist then
          best_dist = dist
          found_url = url
        end
        search_pos = url_end + 1
      end

      if found_url then
        local err = vim.ui.open(found_url)
        if err then
          vim.notify("Failed to open URL: " .. tostring(err), vim.log.levels.ERROR)
        end
      else
        vim.notify("No URL found on current line", vim.log.levels.INFO)
      end
    end, { buffer = buf, desc = "Open URL on current line" })

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
