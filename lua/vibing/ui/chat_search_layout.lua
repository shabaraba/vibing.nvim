local M = {}

function M.create(picker)
  local Layout = require("telescope.pickers.layout")
  local names = { "results", "summary", "preview", "prompt" }

  local function geometry()
    local width = math.max(6, math.floor(vim.o.columns * 0.95) - 2)
    local height = math.max(7, math.floor((vim.o.lines - vim.o.cmdheight - 1) * 0.9) - 2)
    local left = math.max(1, math.floor(width * 0.45) - 1)
    local right = math.max(1, width - left - 2)
    local top = math.max(1, math.floor((height - 2) * 0.35))
    local row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2))
    local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
    local function box(w, h, r, c, title)
      return {
        relative = "editor",
        style = "minimal",
        border = "single",
        width = w,
        height = h,
        row = r,
        col = c,
        title = title,
      }
    end
    return {
      results = box(left, height - 3, row, col, "Chats"),
      prompt = box(left, 1, row + height - 1, col, "Chat Search"),
      summary = box(right, top, row, col + left + 2, "Summary"),
      preview = box(right, height - top - 2, row + top + 2, col + left + 2, "Chat"),
    }
  end

  return Layout({
    picker = picker,
    mount = function(self)
      local boxes = geometry()
      for _, name in ipairs(names) do
        local buf = vim.api.nvim_create_buf(false, true)
        local win = vim.api.nvim_open_win(buf, name == "prompt", boxes[name])
        self[name] = Layout.Window({ bufnr = buf, winid = win })
        vim.wo[win].winhighlight = "Normal:TelescopePreviewNormal,FloatBorder:TelescopePreviewBorder"
        if name == "summary" then
          vim.wo[win].wrap = true
          vim.wo[win].linebreak = true
          vim.bo[buf].filetype = "markdown"
        end
      end
    end,
    update = function(self)
      local boxes = geometry()
      for _, name in ipairs(names) do
        if self[name] and vim.api.nvim_win_is_valid(self[name].winid) then
          vim.api.nvim_win_set_config(self[name].winid, boxes[name])
        end
      end
    end,
    unmount = function(self)
      for _, name in ipairs(names) do
        local window = self[name]
        if window then
          if vim.api.nvim_win_is_valid(window.winid) then
            vim.api.nvim_win_close(window.winid, true)
          end
          if vim.api.nvim_buf_is_valid(window.bufnr) then
            vim.api.nvim_buf_delete(window.bufnr, { force = true })
          end
        end
      end
    end,
  })
end

return M
