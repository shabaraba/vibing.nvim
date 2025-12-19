---@class Vibing.InlineProgress
---インラインアクション実行中の進捗表示ウィンドウ
---右下にフローティングウィンドウでspinnerと操作中ファイルを表示
---@field buf number?
---@field win number?
---@field _spinner_timer any
---@field _spinner_frame number
---@field _modified_files string[]
---@field _current_status string
local InlineProgress = {}
InlineProgress.__index = InlineProgress

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

function InlineProgress:new()
  local instance = setmetatable({}, InlineProgress)
  instance.buf = nil
  instance.win = nil
  instance._spinner_timer = nil
  instance._spinner_frame = 1
  instance._modified_files = {}
  instance._current_status = "Initializing..."
  return instance
end

function InlineProgress:show(title)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    return
  end

  -- Check for headless mode (no UI available)
  local ui = vim.api.nvim_list_uis()[1]
  if not ui then
    return
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"

  local width = 40
  local height = 3
  local row = ui.height - height - 3
  local col = ui.width - width - 2

  self.win = vim.api.nvim_open_win(self.buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. (title or "Vibing") .. " ",
    title_pos = "center",
  })

  vim.wo[self.win].wrap = false

  self:_start_spinner()
  self:_update_display()
end

function InlineProgress:_start_spinner()
  if self._spinner_timer then
    return
  end

  self._spinner_timer = vim.uv.new_timer()
  self._spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if not self.win or not vim.api.nvim_win_is_valid(self.win) then
      self:_stop_spinner()
      return
    end
    self._spinner_frame = (self._spinner_frame % #spinner_frames) + 1
    self:_update_display()
  end))
end

function InlineProgress:_stop_spinner()
  if self._spinner_timer then
    self._spinner_timer:stop()
    self._spinner_timer:close()
    self._spinner_timer = nil
  end
end

function InlineProgress:_update_display()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local spinner = spinner_frames[self._spinner_frame]
  local lines = {
    spinner .. " " .. self._current_status,
    "",
    "Files: " .. #self._modified_files,
  }

  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
end

function InlineProgress:update_status(text)
  self._current_status = text
  self:_update_display()
end

function InlineProgress:update_tool(tool_name, file_path)
  local display_path = file_path
  if #file_path > 30 then
    display_path = "..." .. file_path:sub(-27)
  end
  self._current_status = tool_name .. "(" .. display_path .. ")"
  self:_update_display()
end

function InlineProgress:add_modified_file(file_path)
  for _, f in ipairs(self._modified_files) do
    if f == file_path then
      return
    end
  end
  table.insert(self._modified_files, file_path)
  self:_update_display()
end

function InlineProgress:get_modified_files()
  return self._modified_files
end

function InlineProgress:close()
  self:_stop_spinner()

  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil

  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    vim.api.nvim_buf_delete(self.buf, { force = true })
  end
  self.buf = nil
end

return InlineProgress
