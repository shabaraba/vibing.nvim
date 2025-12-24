---@class Vibing.StatusManager
---Claude側のターン状態を管理し、フローティングウィンドウで通知を表示
---思考中、ツール実行中、応答中、完了などの状態を追跡
---@field _state string 現在の状態 (idle|thinking|tool_use|responding|done|error)
---@field _action_type string? アクションタイプ ("chat"|"inline")
---@field _tool string? 実行中のツール名
---@field _input_summary string? ツール入力の要約
---@field _modified_files string[] 変更されたファイルのリスト
---@field _float_win number? フローティングウィンドウID
---@field _float_buf number? フローティングバッファID
---@field _spinner_timer any? スピナーアニメーション用タイマー
---@field _spinner_frame number 現在のスピナーフレーム番号
---@field _config Vibing.StatusConfig? 設定
local StatusManager = {}
StatusManager.__index = StatusManager

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---新しいStatusManagerインスタンスを作成
---@param config Vibing.StatusConfig? 設定（省略時はデフォルト）
---@return Vibing.StatusManager
function StatusManager:new(config)
  local instance = setmetatable({}, StatusManager)
  instance._state = "idle"
  instance._action_type = nil
  instance._tool = nil
  instance._input_summary = nil
  instance._modified_files = {}
  instance._float_win = nil
  instance._float_buf = nil
  instance._spinner_timer = nil
  instance._spinner_frame = 1
  instance._config = config or {
    enable = true,
    show_tool_details = true,
    auto_dismiss_timeout = 2000,
  }

  return instance
end

---思考中状態に遷移
---@param action_type string "chat" | "inline"
function StatusManager:set_thinking(action_type)
  if not self._config.enable then
    return
  end

  self._state = "thinking"
  self._action_type = action_type
  self._tool = nil
  self._input_summary = nil
  self._modified_files = {}

  self:_update_notification()
  self:_start_spinner()
end

---ツール実行中状態に遷移
---@param tool string ツール名 (Edit, Write, Read, Bash, etc.)
---@param input_summary string? ツール入力の要約（ファイル名など）
function StatusManager:set_tool_use(tool, input_summary)
  if not self._config.enable then
    return
  end

  self._state = "tool_use"
  self._tool = tool
  self._input_summary = input_summary

  self:_update_notification()
end

---応答中状態に遷移
function StatusManager:set_responding()
  if not self._config.enable then
    return
  end

  self._state = "responding"
  self._tool = nil
  self._input_summary = nil

  self:_update_notification()
end

---完了状態に遷移（2秒後に自動でidleに戻る）
---@param modified_files string[]? 変更されたファイルのリスト
function StatusManager:set_done(modified_files)
  if not self._config.enable then
    return
  end

  self._state = "done"
  self._modified_files = modified_files or {}
  self._tool = nil
  self._input_summary = nil

  self:_stop_spinner()
  self:_update_notification()

  -- 自動消去タイマー
  local timeout = self._config.auto_dismiss_timeout or 2000
  vim.defer_fn(function()
    self:clear()
  end, timeout)
end

---エラー状態に遷移
---@param message string エラーメッセージ
function StatusManager:set_error(message)
  if not self._config.enable then
    return
  end

  self._state = "error"
  self._tool = nil
  self._input_summary = nil

  self:_stop_spinner()

  if self._has_noice then
    require("noice").notify(message, vim.log.levels.ERROR, {
      title = self:_get_title(),
    })
  else
    vim.notify("[vibing] " .. message, vim.log.levels.ERROR)
  end
end

---状態をクリア（idleに戻る）
function StatusManager:clear()
  if not self._config.enable then
    return
  end

  self._state = "idle"
  self._action_type = nil
  self._tool = nil
  self._input_summary = nil
  self._modified_files = {}

  self:_stop_spinner()
  self:_dismiss_notification()
end

---現在の状態を取得
---@return table { state: string, action_type: string?, tool: string?, input_summary: string?, modified_files: string[] }
function StatusManager:get_current_state()
  return {
    state = self._state,
    action_type = self._action_type,
    tool = self._tool,
    input_summary = self._input_summary,
    modified_files = vim.deepcopy(self._modified_files),
  }
end

---変更されたファイルを追加
---@param file_path string ファイルパス
function StatusManager:add_modified_file(file_path)
  for _, f in ipairs(self._modified_files) do
    if f == file_path then
      return
    end
  end
  table.insert(self._modified_files, file_path)
end

---変更されたファイルのリストを取得
---@return string[]
function StatusManager:get_modified_files()
  return vim.deepcopy(self._modified_files)
end

---通知のタイトルを生成
---@return string
function StatusManager:_get_title()
  if self._action_type == "chat" then
    return "[vibing] Chat"
  elseif self._action_type == "inline" then
    return "[vibing] Inline"
  else
    return "[vibing]"
  end
end

---通知のメッセージを生成
---@return string
function StatusManager:_get_message()
  local spinner = spinner_frames[self._spinner_frame]

  if self._state == "thinking" then
    return spinner .. " 思考中..."
  elseif self._state == "tool_use" then
    if self._config.show_tool_details and self._input_summary then
      return "⏺ Running " .. self._tool .. "(" .. self._input_summary .. ")"
    else
      return "⏺ Running " .. (self._tool or "tool")
    end
  elseif self._state == "responding" then
    return "✓ Responding..."
  elseif self._state == "done" then
    local count = #self._modified_files
    if count > 0 then
      return "✓ Done (" .. count .. " files modified)"
    else
      return "✓ Done"
    end
  else
    return ""
  end
end

---通知を更新（floating window）
function StatusManager:_update_notification()
  if self._state == "idle" then
    self:_close_float()
    return
  end

  local message = self:_get_message()
  local title = self:_get_title()

  -- Create or update floating window
  self:_show_float(title, message)
end

---フローティングウィンドウを表示または更新
---@param title string タイトル
---@param message string メッセージ
function StatusManager:_show_float(title, message)
  -- Check if window is still valid
  if self._float_win and not vim.api.nvim_win_is_valid(self._float_win) then
    self._float_win = nil
    self._float_buf = nil
  end

  -- Create buffer if needed
  if not self._float_buf or not vim.api.nvim_buf_is_valid(self._float_buf) then
    self._float_buf = vim.api.nvim_create_buf(false, true) -- no file, scratch
    vim.api.nvim_buf_set_option(self._float_buf, 'bufhidden', 'wipe')
  end

  -- Set buffer content
  local lines = {
    title,
    string.rep("─", #title),
  }
  -- Split message by newlines to handle multi-line messages
  local message_lines = vim.split(message, "\n", { plain = true })
  for _, line in ipairs(message_lines) do
    table.insert(lines, line)
  end
  vim.api.nvim_buf_set_lines(self._float_buf, 0, -1, false, lines)

  -- Calculate window size (consider all lines)
  local max_width = vim.fn.strdisplaywidth(title)
  for _, line in ipairs(message_lines) do
    max_width = math.max(max_width, vim.fn.strdisplaywidth(line))
  end
  local width = max_width + 2
  local height = #lines

  -- Get editor dimensions
  local ui = vim.api.nvim_list_uis()[1]
  if not ui then
    -- No UI available (headless mode), skip floating window
    return
  end
  local editor_width = ui.width
  local editor_height = ui.height

  -- Position: bottom-right corner
  local row = editor_height - height - 3
  local col = editor_width - width - 2

  -- Create or update window
  local opts = {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    focusable = false,
    zindex = 50,
  }

  if not self._float_win or not vim.api.nvim_win_is_valid(self._float_win) then
    self._float_win = vim.api.nvim_open_win(self._float_buf, false, opts)
    -- Set window highlight
    vim.api.nvim_win_set_option(self._float_win, 'winhl', 'Normal:Normal,FloatBorder:FloatBorder')
  else
    vim.api.nvim_win_set_config(self._float_win, opts)
  end
end

---フローティングウィンドウを閉じる
function StatusManager:_close_float()
  if self._float_win and vim.api.nvim_win_is_valid(self._float_win) then
    pcall(vim.api.nvim_win_close, self._float_win, true)
  end
  self._float_win = nil

  if self._float_buf and vim.api.nvim_buf_is_valid(self._float_buf) then
    pcall(vim.api.nvim_buf_delete, self._float_buf, { force = true })
  end
  self._float_buf = nil
end

---通知を消去（フローティングウィンドウを閉じる）
function StatusManager:_dismiss_notification()
  self:_close_float()
end

---スピナーアニメーションを開始
function StatusManager:_start_spinner()
  if self._spinner_timer then
    return
  end

  -- vim.notify用のスピナータイマー
  self._spinner_timer = vim.uv.new_timer()
  self._spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if self._state == "idle" or self._state == "done" or self._state == "error" then
      self:_stop_spinner()
      return
    end

    self._spinner_frame = (self._spinner_frame % #spinner_frames) + 1
    self:_update_notification()
  end))
end

---スピナーアニメーションを停止
function StatusManager:_stop_spinner()
  if self._spinner_timer then
    self._spinner_timer:stop()
    self._spinner_timer:close()
    self._spinner_timer = nil
  end
end

return StatusManager
