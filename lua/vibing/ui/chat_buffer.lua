local Context = require("vibing.context")
local BufferIdentifier = require("vibing.utils.buffer_identifier")

---@class Vibing.ChatBuffer
---@field buf number?
---@field win number?
---@field config Vibing.ChatConfig
---@field session_id string?
---@field file_path string?
---@field _chunk_buffer string 未フラッシュのチャンクを蓄積するバッファ
---@field _chunk_timer any チャンクフラッシュ用のタイマー
---@field _last_modified_files string[]? 最後に変更されたファイル一覧（プレビューUI用）
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
  instance._chunk_buffer = ""
  instance._chunk_timer = nil
  instance._last_modified_files = nil
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
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
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
  -- vibingチャット専用のfiletypeを使用（mkdnなどの干渉を防ぐ）
  -- シンタックスハイライトはmarkdownを使用
  vim.bo[self.buf].filetype = "vibing"
  vim.bo[self.buf].syntax = "markdown"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false

  -- ファイルパスが設定されている場合はそれを使う
  if self.file_path then
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  else
    -- 新規の場合は設定に基づいて保存先を決定
    local save_path = self:_get_save_directory()
    vim.fn.mkdir(save_path, "p")
    local filename = os.date("chat-%Y%m%d-%H%M%S.vibing")
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

  if win_config.position == "current" then
    -- 現在のウィンドウで新規バッファを開く（デフォルト）
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win, self.buf)
  elseif win_config.position == "right" then
    vim.cmd("botright vsplit")
    vim.cmd("vertical resize " .. width)
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win, self.buf)
  elseif win_config.position == "left" then
    vim.cmd("topleft vsplit")
    vim.cmd("vertical resize " .. width)
    self.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.win, self.buf)
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
  end
end

---キーマップを設定
function ChatBuffer:_setup_keymaps()
  local vibing = require("vibing")
  local keymaps = vibing.get_config().keymaps
  local buf = self.buf

  -- 他プラグイン（mkdnなど）の干渉を防ぐため遅延設定
  local function set_keymaps()
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    -- 既存のマッピングを削除してから設定
    pcall(vim.keymap.del, "n", keymaps.send, { buffer = buf })

    vim.keymap.set("n", keymaps.send, function()
      self:send_message()
    end, { buffer = buf, desc = "Send message" })

    vim.keymap.set("n", keymaps.cancel, function()
      local adapter = vibing.get_adapter()
      if adapter then
        adapter:cancel()
      end
    end, { buffer = buf, desc = "Cancel request" })

    vim.keymap.set("n", keymaps.add_context, function()
      vim.ui.input({ prompt = "Add context: ", completion = "file" }, function(path)
        if path then
          Context.add(path)
          self:_update_context_line()
        end
      end)
    end, { buffer = buf, desc = "Add context" })

    -- ファイルパス上で diff を表示
    vim.keymap.set("n", keymaps.open_diff, function()
      local FilePath = require("vibing.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        -- Modified Filesに含まれているかチェック
        local modified_files = self:get_last_modified_files()
        if modified_files and #modified_files > 0 then
          -- パスを正規化して比較（[Buffer N]形式は除く）
          local normalized_cursor = BufferIdentifier.normalize_path(file_path)

          for _, mf in ipairs(modified_files) do
            local normalized_mf = BufferIdentifier.normalize_path(mf)

            if normalized_mf == normalized_cursor then
              -- Modified Filesの一部なのでプレビューUIを開く
              local InlinePreview = require("vibing.ui.inline_preview")
              local saved_contents = self:get_last_saved_contents()
              InlinePreview.setup("chat", modified_files, "", saved_contents, file_path)
              return
            end
          end
        end
        -- 通常のdiffを表示
        local GitDiff = require("vibing.utils.git_diff")
        GitDiff.show_diff(file_path)
      end
    end, { buffer = buf, desc = "Open diff for file under cursor" })

    -- ファイルパス上でファイルを開く
    vim.keymap.set("n", keymaps.open_file, function()
      local FilePath = require("vibing.utils.file_path")
      local file_path = FilePath.is_cursor_on_file_path(buf)
      if file_path then
        FilePath.open_file(file_path)
      end
    end, { buffer = buf, desc = "Open file under cursor" })

    -- Modified Filesセクション内で全ファイルのプレビューUIを表示
    vim.keymap.set("n", "gp", function()
      local modified_files = self:get_last_modified_files()
      if not modified_files or #modified_files == 0 then
        vim.notify("No modified files to preview", vim.log.levels.WARN)
        return
      end

      local InlinePreview = require("vibing.ui.inline_preview")
      local saved_contents = self:get_last_saved_contents()
      -- chatモードでプレビューUIを起動（response_textは空、保存内容を渡す）
      InlinePreview.setup("chat", modified_files, "", saved_contents)
    end, { buffer = buf, desc = "Preview all modified files" })

    vim.keymap.set("n", "q", function()
      self:close()
    end, { buffer = buf, desc = "Close chat" })
  end

  -- 即座に設定
  set_keymaps()

  -- 遅延で再設定（他プラグインの後に上書き）
  vim.defer_fn(set_keymaps, 100)

  -- mkdnなどが様々なイベントで上書きする対策
  local group = vim.api.nvim_create_augroup("vibing_chat_keymaps_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "InsertLeave", "TextChanged" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.defer_fn(set_keymaps, 10)
    end,
  })
end

---初期コンテンツを設定
function ChatBuffer:_init_content()
  local vibing = require("vibing")
  local config = vibing.get_config()

  local lines = {
    "---",
    "vibing.nvim: true",
    "session_id: ~",  -- YAMLのnull値
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
    if config.permissions.mode then
      table.insert(lines, "permission_mode: " .. config.permissions.mode)
    end
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

  -- Context行を追加（改行を含む場合は分割）
  local context_text = "Context: " .. Context.format_for_display()
  local context_lines = vim.split(context_text, "\n", { plain = true })
  vim.list_extend(lines, context_lines)

  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  -- "## User"の次の空行（ユーザー入力エリア）にカーソルを設定
  if self:is_open() and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf) then
    local cursor_line = #lines - 2
    if cursor_line > 0 then
      pcall(vim.api.nvim_win_set_cursor, self.win, { cursor_line, 0 })
    end
  end
end

---コンテキスト行を更新（ファイル末尾）
function ChatBuffer:_update_context_line()
  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local context_text = "Context: " .. Context.format_for_display()

  -- 改行を含む場合は分割
  local context_lines = vim.split(context_text, "\n", { plain = true })

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
      context_lines
    )
  else
    -- 末尾に新規追加
    local new_lines = { "" }
    vim.list_extend(new_lines, context_lines)
    vim.api.nvim_buf_set_lines(
      self.buf,
      #lines,
      #lines,
      false,
      new_lines
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
          -- 次の行がリスト項目かどうかを確認してからリストモードに入る
          local next_line = lines[i + 1]
          local is_list_start = value == "" and next_line and next_line:match("^  %- ")
          if is_list_start then
            current_key = key
            current_list = {}
          else
            -- 空の値はnilではなく空文字列として保存
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

---フロントマターのリストフィールドを更新（追加/削除）
---permissions_allow, permissions_deny等のリスト形式フィールド用
---@param key string フィールド名（permissions_allow, permissions_deny等）
---@param value string 追加/削除する値
---@param action "add"|"remove" 操作種別
---@return boolean success
function ChatBuffer:update_frontmatter_list(key, value, action)
  if not key or key == "" or not value or value == "" then
    return false
  end

  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return false
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, 50, false)
  local frontmatter_end = 0
  local key_start = nil
  local key_end = nil
  local current_items = {}

  -- frontmatter解析
  local in_frontmatter = false
  local in_target_list = false

  for i, line in ipairs(lines) do
    if i == 1 and line == "---" then
      in_frontmatter = true
    elseif in_frontmatter and line == "---" then
      frontmatter_end = i
      if in_target_list then
        key_end = i - 1
      end
      break
    elseif in_frontmatter then
      if line:match("^" .. key .. ":") then
        key_start = i
        in_target_list = true
      elseif in_target_list then
        local item = line:match("^  %- (.+)$")
        if item then
          table.insert(current_items, item)
        else
          key_end = i - 1
          in_target_list = false
        end
      end
    end
  end

  if frontmatter_end == 0 then
    return false
  end

  -- リストを更新
  if action == "add" then
    -- 既に存在する場合は追加しない
    for _, item in ipairs(current_items) do
      if item == value then
        return true
      end
    end
    table.insert(current_items, value)
  elseif action == "remove" then
    local new_items = {}
    for _, item in ipairs(current_items) do
      if item ~= value then
        table.insert(new_items, item)
      end
    end
    current_items = new_items
  end

  -- 新しいリスト行を生成
  local new_lines = {}
  if #current_items > 0 then
    table.insert(new_lines, key .. ":")
    for _, item in ipairs(current_items) do
      table.insert(new_lines, "  - " .. item)
    end
  end

  -- バッファを更新
  if key_start then
    -- 既存のキーを置換
    local end_line = key_end or key_start
    vim.api.nvim_buf_set_lines(self.buf, key_start - 1, end_line, false, new_lines)
  elseif #current_items > 0 then
    -- 新規キーを追加（frontmatter終了の直前）
    vim.api.nvim_buf_set_lines(self.buf, frontmatter_end - 1, frontmatter_end - 1, false, new_lines)
  end

  self:update_frontmatter("updated_at", os.date("%Y-%m-%dT%H:%M:%S"), false)
  return true
end

---フロントマターのリストフィールドを取得
---@param key string フィールド名
---@return string[] items
function ChatBuffer:get_frontmatter_list(key)
  local frontmatter = self:parse_frontmatter()
  return frontmatter[key] or {}
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
  -- session_idが有効な文字列の場合のみ設定（空文字列と~はnullとして扱う）
  local sid = frontmatter.session_id
  if type(sid) == "string" and sid ~= "" and sid ~= "~" then
    self.session_id = sid
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

  -- 最後の "## User" 行を見つける（大文字小文字を区別しない）
  for i = #lines, 1, -1 do
    if lines[i]:lower():match("^## user") then
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
    local handled, is_custom = commands.execute(message, self)
    if handled then
      -- コマンドが処理された
      -- カスタムコマンドはM.send()内でadd_user_section()を呼ぶため、ここでは呼ばない
      -- ビルトインコマンドのみここでadd_user_section()を呼ぶ
      if not is_custom then
        self:add_user_section()
      end
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
  -- StatusManagerがスピナー表示を担当するため、ここではスピナーを開始しない
end

---バッファリングされたチャンクをフラッシュしてバッファに書き込む
function ChatBuffer:_flush_chunks()
  if not self.buf or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  if self._chunk_buffer == "" then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  -- バッファリングされた全チャンクを処理
  local chunk_lines = vim.split(self._chunk_buffer, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(self.buf, #lines - 1, #lines, false, chunk_lines)

  -- カーソルを最下部に移動
  if self:is_open() and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf) then
    local new_lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
    local line_count = #new_lines
    if line_count > 0 then
      -- Safely set cursor with error handling
      pcall(vim.api.nvim_win_set_cursor, self.win, { line_count, 0 })
    end
  end

  -- バッファをクリア
  self._chunk_buffer = ""
end

---ストリーミングチャンクを追加（バッファリング有効）
---@param chunk string
function ChatBuffer:append_chunk(chunk)
  -- チャンクをバッファに蓄積
  self._chunk_buffer = self._chunk_buffer .. chunk

  -- 既存のタイマーがあればキャンセル
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
  end

  -- 50ms後にフラッシュするタイマーを設定（複数チャンクをまとめて処理）
  self._chunk_timer = vim.fn.timer_start(50, function()
    self:_flush_chunks()
    self._chunk_timer = nil
  end)
end

---新しいユーザー入力セクションを追加
function ChatBuffer:add_user_section()
  -- 残っているチャンクをフラッシュ
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  self:_flush_chunks()

  local lines = vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
  local new_lines = {
    "",
    "## User",
    "",
  }
  vim.api.nvim_buf_set_lines(self.buf, #lines, #lines, false, new_lines)

  if self:is_open() and vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_buf_is_valid(self.buf) then
    local total = vim.api.nvim_buf_line_count(self.buf)
    if total > 0 then
      pcall(vim.api.nvim_win_set_cursor, self.win, { total, 0 })
    end
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

  local new_filename = base_filename .. ".vibing"
  local new_file_path = chat_dir .. new_filename

  -- ファイル名が重複する場合は連番を追加
  local counter = 1
  while vim.fn.filereadable(new_file_path) == 1 do
    new_filename = base_filename .. "_" .. counter .. ".vibing"
    new_file_path = chat_dir .. new_filename
    counter = counter + 1
  end

  -- バッファ名を更新
  self.file_path = new_file_path
  vim.api.nvim_buf_set_name(self.buf, new_file_path)
end

---最後に変更されたファイル一覧を設定（プレビューUI用）
---@param modified_files string[] 変更されたファイルパスの配列
---@param saved_contents table<string, string[]>? Claude変更前のファイル内容（オプション）
function ChatBuffer:set_last_modified_files(modified_files, saved_contents)
  self._last_modified_files = modified_files
  self._last_saved_contents = saved_contents or {}
end

---最後に変更されたファイル一覧を取得（プレビューUI用）
---@return string[]? 変更されたファイル一覧（設定されていない場合はnil）
function ChatBuffer:get_last_modified_files()
  return self._last_modified_files
end

---最後に保存されたファイル内容を取得（プレビューUI用）
---@return table<string, string[]> Claude変更前のファイル内容
function ChatBuffer:get_last_saved_contents()
  return self._last_saved_contents or {}
end

return ChatBuffer
