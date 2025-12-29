---@class Vibing.Presentation.InlineProgressView
---インラインプログレスビュー
local ProgressView = {}
ProgressView.__index = ProgressView

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---新しいプログレスビューを作成
---@return Vibing.Presentation.InlineProgressView
function ProgressView:new()
  local instance = setmetatable({}, self)
  instance.buf = nil
  instance.win = nil
  instance._spinner_timer = nil
  instance._spinner_frame = 1
  instance._modified_files = {}
  instance._current_status = "Initializing..."
  return instance
end

---プログレスウィンドウを表示
---@param title string?
function ProgressView:show(title)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    return
  end

  local ui = vim.api.nvim_list_uis()[1]
  if not ui then return end

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].bufhidden = "wipe"

  local width, height = 40, 3
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

  require("vibing.utils.ui").apply_wrap_config(self.win)
  self:_start_spinner()
  self:_update_display()
end

---スピナーを開始
function ProgressView:_start_spinner()
  if self._spinner_timer then return end

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

---スピナーを停止
function ProgressView:_stop_spinner()
  if self._spinner_timer then
    self._spinner_timer:stop()
    self._spinner_timer:close()
    self._spinner_timer = nil
  end
end

---表示を更新
function ProgressView:_update_display()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then return end

  local lines = {
    spinner_frames[self._spinner_frame] .. " " .. self._current_status,
    "",
    "Files: " .. #self._modified_files,
  }
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
end

---ステータスを更新
---@param text string
function ProgressView:update_status(text)
  self._current_status = text
  self:_update_display()
end

---ツール情報を更新
---@param tool_name string
---@param file_path string
function ProgressView:update_tool(tool_name, file_path)
  local display = file_path
  if #file_path > 30 then
    display = "..." .. file_path:sub(-27)
  end
  self._current_status = tool_name .. "(" .. display .. ")"
  self:_update_display()
end

---変更ファイルを追加
---@param file_path string
function ProgressView:add_modified_file(file_path)
  if not vim.tbl_contains(self._modified_files, file_path) then
    table.insert(self._modified_files, file_path)
    self:_update_display()
  end
end

---変更ファイル一覧を取得
---@return string[]
function ProgressView:get_modified_files()
  return self._modified_files
end

---ウィンドウを閉じる
function ProgressView:close()
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

return ProgressView
