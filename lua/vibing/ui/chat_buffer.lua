local Context = require("vibing.context")

---@class Vibing.ChatBuffer
---@field buf number?
---@field win number?
---@field config Vibing.ChatConfig
---@field session_id string?
---@field file_path string?
local ChatBuffer = {}
ChatBuffer.__index = ChatBuffer

---@param config Vibing.ChatConfig
---@return Vibing.ChatBuffer
function ChatBuffer:new(config)
  local instance = setmetatable({}, ChatBuffer)
  instance.buf = nil
  instance.win = nil
  instance.config = config
  instance.session_id = nil
  instance.file_path = nil
  return instance
end

---チャットウィンドウを開く
function ChatBuffer:open()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
    return
  end

  self:_create_buffer()
  self:_create_window()
  self:_setup_keymaps()
  self:_init_content()
end

---チャットウィンドウを閉じる
function ChatBuffer:close()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

---ウィンドウが開いているか
---@return boolean
function ChatBuffer:is_open()
  return self.win ~= nil and vim.api.nvim_win_is_valid(self.win)
end

---バッファを作成
function ChatBuffer:_create_buffer()
  if self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  self.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buf].buftype = ""  -- 通常バッファ（保存可能）
  vim.bo[self.buf].filetype = "markdown"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false

  -- ファイルパスが設定されている場合はそれを使う
  if self.file_path then
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  else
    -- 新規の場合は設定に基づいて保存先を決定
    local save_path = self:_get_save_directory()
    vim.fn.mkdir(save_path, "p")
    local filename = os.date("chat-%Y%m%d-%H%M%S.md")
    self.file_path = save_path .. filename
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  end
end

---保存ディレクトリを取得
---@return string directory_path
function ChatBuffer:_get_save_directory()
  local location_type = self.config.save_location_type or "project"

  if location_type == "project" then
    -- プロジェクトローカル
    local project_root = vim.fn.getcwd()
    return project_root .. "/.vibing/chat/"
  elseif location_type == "user" then
    -- ユーザーグローバル
    return vim.fn.stdpath("data") .. "/vibing/chats/"
  elseif location_type == "custom" then
    -- カスタムパス
    local custom_path = self.config.save_dir
    -- 末尾にスラッシュを追加（必要な場合）
    if not custom_path:match("/$") then
      custom_path = custom_path .. "/"
    end
    return custom_path
  else
    -- デフォルトはproject
    return vim.fn.getcwd() .. "/.vibing/chat/"
  end
end

---ウィンドウを作成
function ChatBuffer:_create_window()
  local win_config = self.config.window
  local width = math.floor(vim.o.columns * win_config.width)

  if win_config.position == "right" then
    vim.cmd("botright vsplit")
    vim.cmd("vertical resize " .. width)
  elseif win_config.position == "left" then
    vim.cmd("topleft vsplit")
    vim.cmd("vertical resize " .. width)
  else
    -- float
    local height = math.floor(vim.o.lines * 0.8)
    local row = math.floor((vim.o.lines - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)

    self.win = vim.api.nvim_open_win(self.buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = win_config.border,
    })
    return
  end

  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
end

---キーマップを設定
function ChatBuffer:_setup_keymaps()
  local vibing = require("vibing")
  local keymaps = vibing.get_config().keymaps

  vim.keymap.set("n", keymaps.send, function()
    self:send_message()
  end, { buffer = self.buf, desc = "Send message" })

  vim.keymap.set("n", keymaps.cancel, function()
    local adapter = vibing.get_adapter()
    if adapter then
      adapter:cancel()
    end
  end, { buffer = self.buf, desc = "Cancel request" })

  vim.keymap.set("n", keymaps.add_context, function()
    vim.ui.input({ prompt = "Add context: ", completion = "file" }, function(path)
      if path then
        Context.add(path)
        self:_update_context_line()
      end
    end)
  end, { buffer = self.buf, desc = "Add context" })

  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buf, desc = "Close chat" })
end

---初期コンテンツを設定
function ChatBuffer:_init_content()
  local vibing = require("vibing")
  local config = vibing.get_config()

  local lines = {
    "---",
    "vibing.nvim: true",
    "session_id: ",
    "created_at: " .. os.date("%Y-%m-%dT%H:%M:%S"),
  }

  -- Add default mode and model from config
  if config.agent then
    if config.agent.default_mode then
      table.insert(lines, "mode: " .. config.agent.default_mode)
    end
    if config.agent.default_model then
      table.insert(lines, "model: " .. config.agent.default_model)
    end
  end

  -- Add permissions if configured
  if config.permissions then
    if config.permissions.allow and #config.permissions.allow > 0 then
      table.insert(lines, "permissions_allow:")
      for _, tool in ipairs(config.permissions.allow) do
        table.insert(lines, "  - " .. tool)
      end
    end
    if config.permissions.deny and #config.permissions.deny > 0 then
      table.insert(lines, "permissions_deny:")
      for _, tool in ipairs(config.permissions.deny) do
        table.insert(lines, "  - " .. tool)
      end
    end
  end

  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "# Vibing Chat")
  table.insert(lines, "")
  table.insert(lines, "---")
  table.insert(lines, "")
  table.insert(lines, "## User")
  table.insert(lines, "")
  table.insert(lines, "")
  table.insert(lines, "Context: " .. Context.format_for_display())

  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  -- "## User"の次の空行（ユーザー入力エリア）にカーソルを設定
  vim.api.nvim_win_set_cursor(self.win, { #lines - 2, 0 })
end

---コンテキスト行を更新（ファイル末尾）
function ChatBuffer:_update_context_line()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local context_text = "Context: " .. Context.format_for_display()

  -- 末尾から検索して既存のContext行を見つける
  local context_line_pos = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^Context:") then
      context_line_pos = i
      break
    end
  end

  if context_line_pos then
    -- 既存のContext行を更新
    vim.api.nvim_buf_set_lines(
      self.buf,
      context_line_pos - 1,
      context_line_pos,
      false,
      { context_text }
    )
  else
    -- 末尾に新規追加
    vim.api.nvim_buf_set_lines(
      self.buf,
      #lines,
      #lines,
      false,
      { "", context_text }
    )
  end
end

---YAMLフロントマターをパース
---@return table<string, string>
function ChatBuffer:parse_frontmatter()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 50, false)
  local frontmatter = {}
  local in_frontmatter = false
  local frontmatter_end = 0
  local current_key = nil
  local current_list = nil

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      if current_key and current_list then
        frontmatter[current_key] = current_list
      end
      frontmatter_end = i
      break
    elseif in_frontmatter then
      if line:match("^  %- ") and current_list then
        local item = line:match("^  %- (.+)$")
        if item then
          table.insert(current_list, item)
        end
      else
        if current_key and current_list then
          frontmatter[current_key] = current_list
        end
        local key, value = line:match("^([%w_]+):%s*(.*)$")
        if key then
          if value == "" then
            current_key = key
            current_list = {}
          else
            frontmatter[key] = value
            current_key = nil
            current_list = nil
          end
        end
      end
    end
  end

  return frontmatter
end

---フロントマターのsession_idを更新
---@param session_id string
function ChatBuffer:update_session_id(session_id)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  self.session_id = session_id

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 10, false)
  for i, line in ipairs(lines) do
    if line:match("^session_id:") then
      vim.api.nvim_buf_set_lines(
        self.buf,
        i - 1,
        i,
        false,
        { "session_id: " .. session_id }
      )
      return
    end
  end
end

---フロントマターのフィールドを更新または追加
---@param key string
---@param value string
---@param update_timestamp? boolean
---@return boolean success
function ChatBuffer:update_frontmatter(key, value, update_timestamp)
  if not key or key == "" then
    return false
  end

  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return false
  end

  if update_timestamp == nil then
    update_timestamp = true
  end

  local function escape_pattern(str)
    return str:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 20, false)
  local frontmatter_end = 0
  local key_line = nil
  local escaped_key = escape_pattern(key)

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      -- frontmatter開始
    elseif line == "---" then
      frontmatter_end = i
      break
    elseif line:match("^" .. escaped_key .. ":") then
      key_line = i
    end
  end

  if frontmatter_end == 0 then
    return false
  end

  local new_line = key .. ": " .. value

  if key_line then
    vim.api.nvim_buf_set_lines(self.buf, key_line - 1, key_line, false, { new_line })
  else
    vim.api.nvim_buf_set_lines(self.buf, frontmatter_end - 1, frontmatter_end - 1, false, { new_line })
  end

  if update_timestamp and key ~= "updated_at" then
    self:update_frontmatter("updated_at", os.date("%Y-%m-%dT%H:%M:%S"), false)
  end

  return true
end

---保存されたチャットファイルを読み込む
---@param file_path string
---@return boolean success
function ChatBuffer:load_from_file(file_path)
  if not vim.fn.filereadable(file_path) then
    return false
  end

  self.file_path = file_path
  self:_create_buffer()

  local content = vim.fn.readfile(file_path)
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, content)

  local frontmatter = self:parse_frontmatter()
  if frontmatter.session_id and frontmatter.session_id ~= "" then
    self.session_id = frontmatter.session_id
  end

  return true
end

---セッションIDを取得
---@return string?
function ChatBuffer:get_session_id()
  return self.session_id
end

---会話履歴全体を抽出
---@return {role: string, content: string}[]
function ChatBuffer:extract_conversation()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local conversation = {}
  local current_role = nil
  local current_content = {}

  for _, line in ipairs(lines) do
    if line:match("^## User") then
      -- 前のセクションを保存
      if current_role and #current_content > 0 then
        table.insert(conversation, {
          role = current_role,
          content = vim.trim(table.concat(current_content, "\n"))
        })
      end
      current_role = "user"
      current_content = {}
    elseif line:match("^## Assistant") then
      -- 前のセクションを保存
      if current_role and #current_content > 0 then
        table.insert(conversation, {
          role = current_role,
          content = vim.trim(table.concat(current_content, "\n"))
        })
      end
      current_role = "assistant"
      current_content = {}
    elseif current_role and not line:match("^#") and not line:match("^---") and not line:match("^Context:") then
      table.insert(current_content, line)
    end
  end

  -- 最後のセクションを保存
  if current_role and #current_content > 0 then
    local content = vim.trim(table.concat(current_content, "\n"))
    if content ~= "" then
      table.insert(conversation, {
        role = current_role,
        content = content
      })
    end
  end

  return conversation
end

---ユーザーメッセージを抽出（最後の## Userセクションから）
---@return string?
function ChatBuffer:extract_user_message()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_user_line = nil

  -- 最後の "## User" 行を見つける
  for i = #lines, 1, -1 do
    if lines[i]:match("^## User") then
      last_user_line = i
      break
    end
  end

  if not last_user_line then
    return nil
  end

  -- ## User の次の行からメッセージを収集
  local message_lines = {}
  for i = last_user_line + 1, #lines do
    local line = lines[i]
    -- 次のセクションに達したら終了
    if line:match("^## ") or line:match("^---") then
      break
    end
    table.insert(message_lines, line)
  end

  -- 空行を除去
  while #message_lines > 0 and message_lines[1] == "" do
    table.remove(message_lines, 1)
  end
  while #message_lines > 0 and message_lines[#message_lines] == "" do
    table.remove(message_lines)
  end

  if #message_lines == 0 then
    return nil
  end

  return table.concat(message_lines, "\n")
end

---メッセージを送信
function ChatBuffer:send_message()
  local message = self:extract_user_message()
  if not message then
    vim.notify("[vibing] No message to send", vim.log.levels.WARN)
    return
  end

  -- スラッシュコマンドかチェック
  local commands = require("vibing.chat.commands")
  if commands.is_command(message) then
    local handled = commands.execute(message, self)
    if handled then
      -- コマンドが処理されたので、ユーザー入力部分をクリア
      self:add_user_section()
      return
    end
  end

  -- 通常のメッセージ送信
  require("vibing.actions.chat").send(self, message)
end

-- スピナーフレーム
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---アシスタントの応答を追加開始
function ChatBuffer:start_response()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local new_lines = {
    "",
    "## Assistant",
    "",
  }
  vim.api.nvim_buf_set_lines(self.buf, #lines, #lines, false, new_lines)
  self:start_spinner()
end

---スピナーを開始
function ChatBuffer:start_spinner()
  if self._spinner_timer then
    return -- 既に動作中
  end

  self._spinner_frame = 1
  self._spinner_line = vim.api.nvim_buf_line_count(self.buf)
  self._first_chunk_received = false

  -- 初期スピナー表示
  vim.api.nvim_buf_set_lines(
    self.buf,
    self._spinner_line - 1,
    self._spinner_line,
    false,
    { spinner_frames[1] .. " Thinking..." }
  )

  -- タイマーでスピナーをアニメーション
  self._spinner_timer = vim.uv.new_timer()
  self._spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
      self:stop_spinner()
      return
    end

    if self._first_chunk_received then
      self:stop_spinner()
      return
    end

    self._spinner_frame = (self._spinner_frame % #spinner_frames) + 1
    pcall(vim.api.nvim_buf_set_lines, self.buf, self._spinner_line - 1, self._spinner_line, false, {
      spinner_frames[self._spinner_frame] .. " Thinking..."
    })
  end))
end

---スピナーを停止
function ChatBuffer:stop_spinner()
  if self._spinner_timer then
    self._spinner_timer:stop()
    self._spinner_timer:close()
    self._spinner_timer = nil
  end

  -- スピナー行をクリア
  if self._spinner_line and self.buf and vim.api.nvim_buf_is_valid(self.buf) then
    local current_line = vim.api.nvim_buf_get_lines(self.buf, self._spinner_line - 1, self._spinner_line, false)[1] or ""
    if current_line:match("^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]") then
      vim.api.nvim_buf_set_lines(self.buf, self._spinner_line - 1, self._spinner_line, false, { "" })
    end
  end
  self._spinner_line = nil
end

---ストリーミングチャンクを追加
---@param chunk string
function ChatBuffer:append_chunk(chunk)
  -- 最初のチャンクでスピナーを停止
  if not self._first_chunk_received then
    self._first_chunk_received = true
    self:stop_spinner()
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  -- チャンクに改行が含まれる場合
  local chunk_lines = vim.split(chunk, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(self.buf, #lines - 1, #lines, false, chunk_lines)

  -- カーソルを最下部に移動
  if self:is_open() then
    local new_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    vim.api.nvim_win_set_cursor(self.win, { #new_lines, 0 })
  end
end

---新しいユーザー入力セクションを追加
function ChatBuffer:add_user_section()
  -- スピナーが残っていれば停止
  self:stop_spinner()
  self._first_chunk_received = false

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local new_lines = {
    "",
    "## User",
    "",
  }
  vim.api.nvim_buf_set_lines(self.buf, #lines, #lines, false, new_lines)

  if self:is_open() then
    local total = vim.api.nvim_buf_line_count(self.buf)
    vim.api.nvim_win_set_cursor(self.win, { total, 0 })
  end
end

---@return number?
function ChatBuffer:get_buffer()
  return self.buf
end

---最初のメッセージからファイル名を更新
---@param message string
function ChatBuffer:update_filename_from_message(message)
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  -- 既にファイル名が意味のある名前になっている場合はスキップ
  if self.file_path and not self.file_path:match("chat_%d+_%d+") then
    return
  end

  local filename_util = require("vibing.utils.filename")
  local base_filename = filename_util.generate_from_message(message)

  -- 新しいファイルパスを生成
  local project_root = vim.fn.getcwd()
  local chat_dir = project_root .. "/.vibing/chat/"
  vim.fn.mkdir(chat_dir, "p")

  local new_filename = base_filename .. ".md"
  local new_file_path = chat_dir .. new_filename

  -- ファイル名が重複する場合は連番を追加
  local counter = 1
  while vim.fn.filereadable(new_file_path) == 1 do
    new_filename = base_filename .. "_" .. counter .. ".md"
    new_file_path = chat_dir .. new_filename
    counter = counter + 1
  end

  -- バッファ名を更新
  self.file_path = new_file_path
  vim.api.nvim_buf_set_name(self.buf, new_file_path)
end

return ChatBuffer
