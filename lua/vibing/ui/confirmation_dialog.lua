---@class Vibing.UI.ConfirmationDialog
local M = {}

---@param opts {title: string, lines: string[], on_confirm: fun(), on_cancel: fun()}
function M.show(opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")

  local selected = 2
  local namespace = vim.api.nvim_create_namespace("vibing_confirmation_dialog")

  local function update_display()
    local yes_prefix = selected == 1 and "> " or "  "
    local no_prefix = selected == 2 and "> " or "  "
    local display_lines = vim.list_extend(vim.deepcopy(opts.lines), {
      "",
      yes_prefix .. "Yes - Confirm",
      no_prefix .. "No - Cancel",
      "",
      "Use j/k to select, <CR> to confirm, <Esc> to cancel",
    })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, display_lines)

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    local highlight_line = #opts.lines + 1 + (selected - 1)
    vim.api.nvim_buf_add_highlight(bufnr, namespace, "TelescopeSelection", highlight_line, 0, -1)
  end

  local width = 60
  local height = #opts.lines + 5
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. opts.title .. " ",
    title_pos = "center",
  })

  update_display()

  local function toggle_selection()
    selected = selected == 1 and 2 or 1
    update_display()
  end

  local keymap_opts = { noremap = true, silent = true }

  vim.api.nvim_buf_set_keymap(bufnr, "n", "j", "", vim.tbl_extend("force", keymap_opts, {
    callback = toggle_selection,
  }))

  vim.api.nvim_buf_set_keymap(bufnr, "n", "k", "", vim.tbl_extend("force", keymap_opts, {
    callback = toggle_selection,
  }))

  vim.api.nvim_buf_set_keymap(bufnr, "n", "<CR>", "", vim.tbl_extend("force", keymap_opts, {
    callback = function()
      vim.api.nvim_win_close(win, true)
      if selected == 1 then
        opts.on_confirm()
      else
        opts.on_cancel()
      end
    end,
  }))

  vim.api.nvim_buf_set_keymap(bufnr, "n", "<Esc>", "", vim.tbl_extend("force", keymap_opts, {
    callback = function()
      vim.api.nvim_win_close(win, true)
      opts.on_cancel()
    end,
  }))
end

return M
