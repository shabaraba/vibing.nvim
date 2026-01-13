---@class Vibing.InlinePreview.Keymaps
---インラインプレビューのキーマップ設定モジュール
local M = {}

---キーマップを設定
---@param state Vibing.InlinePreview.State
---@param handlers table ハンドラー関数のテーブル
function M.setup(state, handlers)
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

  for buf_type, buf in pairs(buffers) do
    -- Enter: ファイル選択（Filesバッファのみ）
    if buf_type == "files" then
      vim.keymap.set("n", "<CR>", handlers.on_file_select_from_cursor, 
        { buffer = buf, silent = true, desc = "Select file" })
    end

    -- 共通キーマップ
    vim.keymap.set("n", "a", handlers.on_accept, 
      { buffer = buf, silent = true, desc = "Accept changes" })
    vim.keymap.set("n", "r", handlers.on_reject, 
      { buffer = buf, silent = true, desc = "Reject changes" })
    vim.keymap.set("n", "q", handlers.on_quit, 
      { buffer = buf, silent = true, desc = "Quit" })
    vim.keymap.set("n", "<Esc>", handlers.on_quit, 
      { buffer = buf, silent = true, desc = "Quit" })
    vim.keymap.set("n", "b", handlers.save_as_vibing, 
      { buffer = buf, silent = true, desc = "Save to buffer (vibing file)" })

    -- Tab/Shift-Tab
    if state.mode == "inline" then
      -- Inline mode: アコーディオン式パネル切り替え
      vim.keymap.set("n", "<Tab>", function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win == state.win_files then
          handlers.switch_panel("diff")
        elseif current_win == state.win_diff then
          handlers.switch_panel("response")
        elseif current_win == state.win_response then
          if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
            vim.api.nvim_set_current_win(state.win_files)
          end
        end
      end, { buffer = buf, silent = true, desc = "Next panel" })

      vim.keymap.set("n", "<S-Tab>", function()
        local current_win = vim.api.nvim_get_current_win()
        if current_win == state.win_files then
          handlers.switch_panel("response")
        elseif current_win == state.win_response then
          handlers.switch_panel("diff")
        elseif current_win == state.win_diff then
          if state.win_files and vim.api.nvim_win_is_valid(state.win_files) then
            vim.api.nvim_set_current_win(state.win_files)
          end
        end
      end, { buffer = buf, silent = true, desc = "Previous panel" })
    else
      -- Chat mode: ウィンドウ循環
      vim.keymap.set("n", "<Tab>", function()
        handlers.cycle_window(1)
      end, { buffer = buf, silent = true, desc = "Next window" })

      vim.keymap.set("n", "<S-Tab>", function()
        handlers.cycle_window(-1)
      end, { buffer = buf, silent = true, desc = "Previous window" })
    end
  end
end

return M
