local Context = require("vibing.application.context.manager")
local WindowManager = require("vibing.presentation.chat.modules.window_manager")
local FileManager = require("vibing.presentation.chat.modules.file_manager")
local FrontmatterHandler = require("vibing.presentation.chat.modules.frontmatter_handler")
local Renderer = require("vibing.presentation.chat.modules.renderer")
local StreamingHandler = require("vibing.presentation.chat.modules.streaming_handler")
local ConversationExtractor = require("vibing.presentation.chat.modules.conversation_extractor")
local KeymapHandler = require("vibing.presentation.chat.modules.keymap_handler")

---@class Vibing.ChatBuffer
---@field buf number?
---@field win number?
---@field config Vibing.ChatConfig
---@field session_id string?
---@field file_path string?
---@field _chunk_buffer string 未フラッシュのチャンクを蓄積するバッファ
---@field _chunk_timer any チャンクフラッシュ用のタイマー
---@field _pending_choices table[]? add_user_section()後に挿入する選択肢
---@field _pending_approval table? add_user_section()後に挿入する承認要求UI
---@field _current_handle_id string? 実行中のリクエストのハンドルID
---@field _session_allow table セッションレベルの許可リスト
---@field _session_deny table セッションレベルの拒否リスト
---@field _once_tools table? 一時許可/拒否ツールのトラッキング（次のメッセージでクリア）
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
  instance._pending_choices = nil
  instance._pending_approval = nil
  instance._current_handle_id = nil
  instance._session_allow = {}
  instance._session_deny = {}
  instance._once_tools = nil
  return instance
end

---チャットウィンドウを開く
function ChatBuffer:open()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.win)
    return
  end

  local buffer_existed = self.buf and vim.api.nvim_buf_is_valid(self.buf)
  local has_content = false

  if buffer_existed then
    local line_count = vim.api.nvim_buf_line_count(self.buf)
    has_content = line_count > 1
      or (line_count == 1 and vim.api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] ~= "")
  end

  self:_create_buffer()
  self:_create_window()
  self:_setup_keymaps()

  if not has_content then
    local cursor_line = Renderer.init_content(self.buf, self.session)
    if self:is_open() and vim.api.nvim_win_is_valid(self.win) and cursor_line > 0 then
      pcall(vim.api.nvim_win_set_cursor, self.win, { cursor_line, 0 })
    end
  end
end

---チャットウィンドウを閉じる
function ChatBuffer:close()
  -- 実行中のリクエストをキャンセル
  if self._current_handle_id then
    local vibing = require("vibing")
    local adapter = vibing.get_adapter()
    if adapter then
      adapter:cancel(self._current_handle_id)
    end
    self._current_handle_id = nil
  end

  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    if self.config.window.position == "current" then
      local alt_buf = vim.fn.bufnr("#")
      if alt_buf ~= -1 and vim.api.nvim_buf_is_valid(alt_buf) and alt_buf ~= self.buf then
        vim.api.nvim_win_set_buf(self.win, alt_buf)
      else
        local new_buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_win_set_buf(self.win, new_buf)
      end
    else
      local win_count = #vim.api.nvim_list_wins()
      if win_count > 1 then
        vim.api.nvim_win_close(self.win, true)
      end
    end
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
  vim.bo[self.buf].buftype = ""
  vim.bo[self.buf].filetype = "vibing"
  vim.bo[self.buf].syntax = "markdown"
  vim.bo[self.buf].modifiable = true
  vim.bo[self.buf].swapfile = false

  if self.config.window.position == "back" then
    vim.bo[self.buf].buflisted = true
  end

  if self.file_path then
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  else
    local save_path = FileManager.get_save_directory(self.config)
    vim.fn.mkdir(save_path, "p")
    local filename = FileManager.generate_unique_filename()
    self.file_path = save_path .. filename
    vim.api.nvim_buf_set_name(self.buf, self.file_path)
  end
end

---ウィンドウを作成
function ChatBuffer:_create_window()
  self.win = WindowManager.create_window(self.buf, self.config.window)
  WindowManager.apply_wrap_config(self.win)
end

---キーマップを設定
function ChatBuffer:_setup_keymaps()
  local vibing = require("vibing")
  local keymaps = vibing.get_config().keymaps

  local callbacks = {
    send_message = function()
      self:send_message()
    end,
    cancel = function()
      local adapter = vibing.get_adapter()
      if adapter then
        adapter:cancel()
      end
    end,
    update_context_line = function()
      Renderer.updateContextLine(self.buf)
    end,
    close = function()
      self:close()
    end,
  }

  KeymapHandler.setup(self.buf, callbacks, keymaps)
end

---YAMLフロントマターをパース
---@return table<string, string|string[]|number|boolean>
function ChatBuffer:parse_frontmatter()
  return FrontmatterHandler.parse(self.buf)
end

---フロントマターのsession_idを更新
---@param session_id string|nil セッションID（nilの場合はセッションをリセット）
function ChatBuffer:update_session_id(session_id)
  self.session_id = session_id
  -- nilの場合は"~"を設定してYAMLでnullとして扱う
  FrontmatterHandler.update_session_id(self.buf, session_id or "~")
end

---フロントマターのフィールドを更新または追加
---@param key string
---@param value string
---@param update_timestamp? boolean
---@return boolean success
function ChatBuffer:update_frontmatter(key, value, update_timestamp)
  return FrontmatterHandler.update_field(self.buf, key, value, update_timestamp)
end

---フロントマターのリストフィールドを更新（追加/削除）
---@param key string フィールド名
---@param value string 追加/削除する値
---@param action "add"|"remove" 操作種別
---@return boolean success
function ChatBuffer:update_frontmatter_list(key, value, action)
  return FrontmatterHandler.update_list(self.buf, key, value, action)
end

---フロントマターのリストフィールドを取得
---@param key string フィールド名
---@return string[] items
function ChatBuffer:get_frontmatter_list(key)
  return FrontmatterHandler.get_list(self.buf, key)
end

---保存されたチャットファイルを読み込む
---@param file_path string
---@return boolean success
function ChatBuffer:load_from_file(file_path)
  local success = FileManager.load_from_file(self.buf, file_path)
  if success then
    self.file_path = file_path
    local frontmatter = self:parse_frontmatter()
    local sid = frontmatter.session_id
    if type(sid) == "string" and sid ~= "" and sid ~= "~" then
      self.session_id = sid
    end
    -- NOTE: Diff display uses patch files in .vibing/patches/<session_id>/
    -- The gd keymap reads patch files directly via PatchFinder and PatchViewer
  end
  return success
end

---セッションIDを取得
---@return string?
function ChatBuffer:get_session_id()
  return self.session_id
end

---会話履歴全体を抽出
---@return {role: string, content: string}[]
function ChatBuffer:extract_conversation()
  return ConversationExtractor.extract_conversation(self.buf)
end

---ユーザーメッセージを抽出（最後の## Userセクション）
---@return string?
function ChatBuffer:extract_user_message()
  return ConversationExtractor.extract_user_message(self.buf)
end

---メッセージを送信
function ChatBuffer:send_message()
  -- Clean up :once tools (JS side removes during use, but this is a safety net)
  if self._once_tools then
    for _, once_tool in ipairs(self._once_tools) do
      -- Remove from allow list
      for i = #self._session_allow, 1, -1 do
        if self._session_allow[i] == once_tool then
          table.remove(self._session_allow, i)
        end
      end
      -- Remove from deny list
      for i = #self._session_deny, 1, -1 do
        if self._session_deny[i] == once_tool then
          table.remove(self._session_deny, i)
        end
      end
    end
    self._once_tools = nil
  end

  local message = self:extract_user_message()
  if not message then
    vim.notify("[vibing] No message to send", vim.log.levels.WARN)
    return
  end

  ConversationExtractor.commit_user_message(self.buf)

  local commands = require("vibing.application.chat.commands")
  if commands.is_command(message) then
    local handled, expanded = commands.execute(message, self)
    if handled then
      if expanded then
        message = expanded
      else
        self:add_user_section()
        return
      end
    end
  end

  -- Check if message is an approval response
  -- Only process if there's a pending approval request
  local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  if self._pending_approval and ApprovalParser.is_approval_response(message) then
    local approval = ApprovalParser.parse_approval_response(message)
    if approval then
      -- Update session permissions and check for errors
      local success, err = pcall(function()
        self:update_session_permissions(approval)
      end)

      if not success then
        vim.notify(
          string.format("[vibing] Failed to update permissions: %s", tostring(err)),
          vim.log.levels.ERROR
        )
        return
      end

      -- Get tool name and input for message (before clearing _pending_approval)
      local tool = self._pending_approval.tool
      local approval_input = self._pending_approval.input or {}

      -- Clear pending approval after processing
      self._pending_approval = nil

      -- Replace user's approval message with a clear instruction to retry
      -- Include the tool name and original input so Claude can retry exactly

      local is_allow = approval.action == "allow_once" or approval.action == "allow_for_session"
      if is_allow then
        local input_summary = self:_build_approval_input_summary(tool, approval_input)
        message = string.format("I approved the %s tool%s. Please proceed with the same operation.", tool, input_summary)
      else
        message = string.format("I denied the %s tool. Please use a different approach.", tool)
      end

      -- Continue to normal message flow with the replaced message
    else
      -- is_approval_response returned true but parsing failed
      vim.notify(
        "[vibing] Failed to parse approval response. "
          .. "Please ensure only ONE option remains (use 'dd' to delete unwanted lines), then press <CR> again.",
        vim.log.levels.WARN
      )
      return
    end
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  local config = vibing.get_config()
  local SendMessage = require("vibing.application.chat.send_message")

  local callbacks = {
    extract_conversation = function()
      return self:extract_conversation()
    end,
    update_filename_from_message = function(msg)
      return self:update_filename_from_message(msg)
    end,
    start_response = function()
      return self:start_response()
    end,
    parse_frontmatter = function()
      return self:parse_frontmatter()
    end,
    append_chunk = function(chunk)
      return self:append_chunk(chunk)
    end,
    get_session_id = function()
      return self:get_session_id()
    end,
    update_session_id = function(session_id)
      return self:update_session_id(session_id)
    end,
    add_user_section = function()
      return self:add_user_section()
    end,
    get_bufnr = function()
      return self.buf
    end,
    insert_choices = function(questions)
      return self:insert_choices(questions)
    end,
    insert_approval_request = function(tool, input, options)
      return self:insert_approval_request(tool, input, options)
    end,
    get_session_allow = function()
      return self:get_session_allow()
    end,
    get_session_deny = function()
      return self:get_session_deny()
    end,
    clear_handle_id = function()
      self._current_handle_id = nil
    end,
  }

  -- リクエストを送信してhandle_idを保存
  local handle_id = SendMessage.execute(adapter, callbacks, message, config)
  if handle_id then
    self._current_handle_id = handle_id
  end

  if self:is_open() then
    Renderer.moveCursorToEnd(self.win, self.buf)
  end
end

---アシスタントの応答を追加開始
function ChatBuffer:start_response()
  StreamingHandler.start_response(self.buf)
end

---バッファリングされたチャンクをフラッシュ
function ChatBuffer:_flush_chunks()
  self._chunk_buffer = StreamingHandler.flush_chunks(self.buf, self.win, self._chunk_buffer)
end

---ストリーミングチャンクを追加（バッファリング有効）
---@param chunk string
function ChatBuffer:append_chunk(chunk)
  self._chunk_buffer = self._chunk_buffer .. chunk

  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
  end

  self._chunk_timer = vim.fn.timer_start(50, function()
    self:_flush_chunks()
    self._chunk_timer = nil
  end)
end

---新しいユーザー入力セクションを追加
function ChatBuffer:add_user_section()
  if self._chunk_timer then
    vim.fn.timer_stop(self._chunk_timer)
    self._chunk_timer = nil
  end
  self:_flush_chunks()

  Renderer.addUserSection(self.buf, self.win, self._pending_choices, self._pending_approval)
  self._pending_choices = nil
  -- NOTE: Don't clear _pending_approval here!
  -- It needs to persist until the user sends their approval response.
  -- It will be cleared in send_message() after processing the approval.
end

---@return number?
function ChatBuffer:get_buffer()
  return self.buf
end

---最初のメッセージからファイル名を更新
---@param message string
function ChatBuffer:update_filename_from_message(message)
  local new_path = FileManager.update_filename_from_message(self.buf, self.file_path, message)
  if new_path then
    self.file_path = new_path
  end
end

---AskUserQuestion の選択肢を保存
---@param questions table Agent SDKから受け取った質問構造
function ChatBuffer:insert_choices(questions)
  self._pending_choices = questions
end

---承認入力のサマリーを生成
---@param tool string ツール名
---@param input table ツール入力
---@return string 空文字列または " (key: value)" 形式のサマリー
function ChatBuffer:_build_approval_input_summary(tool, input)
  local tool_input_keys = {
    Bash = "command",
    Read = "file_path",
    Write = "file_path",
    Edit = "file_path",
    WebSearch = "query",
    WebFetch = "query",
  }

  local key = tool_input_keys[tool]
  if key and input[key] then
    local label = key == "file_path" and "file" or key
    return string.format(" (%s: %s)", label, input[key])
  end

  return ""
end

---ツール承認要求UIを保存
---@param tool string ツール名
---@param input table ツール入力
---@param options table 承認オプション
function ChatBuffer:insert_approval_request(tool, input, options)
  -- Store for later insertion in add_user_section()
  self._pending_approval = {
    tool = tool,
    input = input,
    options = options,
  }
end

---セッション許可/拒否を更新（承認レスポンス処理）
---@param approval {action: string, tool: string?} パースされた承認データ
function ChatBuffer:update_session_permissions(approval)
  -- Validate approval action
  local valid_actions = {
    allow_once = true,
    deny_once = true,
    allow_for_session = true,
    deny_for_session = true,
  }
  if not approval.action or not valid_actions[approval.action] then
    vim.notify(
      string.format(
        "[vibing] Invalid approval action: '%s' for tool '%s'",
        tostring(approval.action),
        tostring(self._pending_approval and self._pending_approval.tool or "unknown")
      ),
      vim.log.levels.ERROR
    )
    return
  end

  -- Get tool name from pending approval (not from parsed message)
  local tool = self._pending_approval and self._pending_approval.tool
  if not tool or type(tool) ~= "string" or tool == "" then
    vim.notify("[vibing] Invalid approval: missing or invalid tool name", vim.log.levels.ERROR)
    return
  end

  -- Helper to add unique item to list
  local function add_unique(list, value)
    if not vim.tbl_contains(list, value) then
      table.insert(list, value)
    end
  end

  -- Update session-level permissions based on action
  if approval.action == "allow_once" then
    -- Add with :once suffix for one-time use
    local tool_once = tool .. ":once"
    add_unique(self._session_allow, tool_once)
    -- Track for cleanup (JS side also removes, but this is a safety net)
    self._once_tools = self._once_tools or {}
    add_unique(self._once_tools, tool_once)
  elseif approval.action == "deny_once" then
    -- Add with :once suffix for one-time denial
    local tool_once = tool .. ":once"
    add_unique(self._session_deny, tool_once)
    self._once_tools = self._once_tools or {}
    add_unique(self._once_tools, tool_once)
  elseif approval.action == "allow_for_session" then
    -- Add to allow list if not already present
    if not vim.tbl_contains(self._session_allow, tool) then
      table.insert(self._session_allow, tool)
    end
    -- Remove from deny list if present (mutual exclusivity)
    self._session_deny = vim.tbl_filter(function(t)
      return t ~= tool
    end, self._session_deny)

    -- Update frontmatter: add to permissions_allow
    self:update_frontmatter_list("permissions_allow", tool, "add")
    -- Update frontmatter: remove from permissions_deny (if present)
    self:update_frontmatter_list("permissions_deny", tool, "remove")
    -- Update frontmatter: remove from permissions_ask (if present)
    self:update_frontmatter_list("permissions_ask", tool, "remove")

  elseif approval.action == "deny_for_session" then
    -- Add to deny list if not already present
    if not vim.tbl_contains(self._session_deny, tool) then
      table.insert(self._session_deny, tool)
    end
    -- Remove from allow list if present (mutual exclusivity)
    self._session_allow = vim.tbl_filter(function(t)
      return t ~= tool
    end, self._session_allow)

    -- Update frontmatter: add to permissions_deny
    self:update_frontmatter_list("permissions_deny", tool, "add")
    -- Update frontmatter: remove from permissions_allow (if present)
    self:update_frontmatter_list("permissions_allow", tool, "remove")
    -- Update frontmatter: remove from permissions_ask (if present)
    self:update_frontmatter_list("permissions_ask", tool, "remove")
  end
end

---セッションレベルの許可リストを取得
---@return table
function ChatBuffer:get_session_allow()
  return vim.deepcopy(self._session_allow)
end

---セッションレベルの拒否リストを取得
---@return table
function ChatBuffer:get_session_deny()
  return vim.deepcopy(self._session_deny)
end

return ChatBuffer
