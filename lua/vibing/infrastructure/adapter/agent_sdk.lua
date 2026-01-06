local Base = require("vibing.infrastructure.adapter.base")

---@class Vibing.AgentSDKAdapter : Vibing.Adapter
---@field _handles table<string, table> vim.system()で起動したプロセスハンドルのマップ（handle_id -> handle）
---@field _sessions table<string, string> セッションIDのマップ（handle_id -> session_id）
---@field _plugin_root string プラグインのルートディレクトリパス
---@field _stdin_handles table<string, table> stdinハンドルのマップ（handle_id -> stdin pipe）
local AgentSDK = setmetatable({}, { __index = Base })
AgentSDK.__index = AgentSDK

---新しいAgentSDKアダプターインスタンスを作成
---Claude Agent SDKを使用してClaudeと通信する推奨アダプター
---bin/agent-wrapper.mjsを介してNode.jsプロセスとして動作
---@param config Vibing.Config プラグイン設定
---@return Vibing.AgentSDKAdapter 新しいアダプターインスタンス
function AgentSDK:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, AgentSDK)
  instance.name = "agent_sdk"
  instance._handles = {}
  instance._sessions = {}
  instance._stdin_handles = {}
  -- Find plugin root directory
  local source = debug.getinfo(1, "S").source:sub(2)
  instance._plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  -- Initialize random seed for handle ID generation
  math.randomseed(vim.loop.hrtime())
  return instance
end

---ラッパースクリプトのパスを取得
---bin/agent-wrapper.mjsの絶対パスを返す
---@return string ラッパースクリプトの絶対パス
function AgentSDK:get_wrapper_path()
  return self._plugin_root .. "/bin/agent-wrapper.mjs"
end

---コマンドライン引数を構築
---Node.jsラッパースクリプトの実行コマンドを生成
---mode, model, context, session, permissionsを設定から反映
---opts内の値はfrontmatterから渡され、グローバル設定より優先される
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキストファイル等のオプション
---@param session_id string? セッションID（nilの場合は新規セッション）
-- Build the Node.js command-line arguments to invoke the agent wrapper for the given prompt and options.
-- @param prompt The prompt text to provide to the agent.
-- @param opts Table of frontmatter and runtime options that may influence the command (e.g. mode, model, context entries like "@file:<path>", permissions_allow, permissions_deny, permission_mode).
-- @param session_id Optional session ID for resuming conversations.
-- @return string[] Array of command and arguments ready to be executed (first element is the Node executable followed by wrapper path and flags).
function AgentSDK:build_command(prompt, opts, session_id)
  local cmd = { "node", self:get_wrapper_path() }

  table.insert(cmd, "--cwd")
  table.insert(cmd, vim.fn.getcwd())

  -- Add mode: opts (frontmatter) > config default
  local mode = opts.mode
  if not mode and self.config.agent and self.config.agent.default_mode then
    mode = self.config.agent.default_mode
  end
  if mode then
    table.insert(cmd, "--mode")
    table.insert(cmd, mode)
  end

  -- Add model: opts (frontmatter) > config default
  local model = opts.model
  if not model and self.config.agent and self.config.agent.default_model then
    model = self.config.agent.default_model
  end
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  -- Add context files
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      local path = ctx:sub(7)
      table.insert(cmd, "--context")
      table.insert(cmd, path)
    end
  end

  -- Add session ID for resuming (V2 API handles this properly)
  if session_id then
    table.insert(cmd, "--session")
    table.insert(cmd, session_id)
  end

  -- Add permissions: Always use frontmatter (opts) only
  -- Config is only used as a template when creating new chat files
  local allow_tools = opts.permissions_allow
  -- Add MCP tools for vibing.nvim integration (always allowed)
  if allow_tools then
    allow_tools = vim.deepcopy(allow_tools)
  else
    allow_tools = {}
  end
  table.insert(allow_tools, "mcp__vibing-nvim__*")

  if #allow_tools > 0 then
    table.insert(cmd, "--allow")
    table.insert(cmd, table.concat(allow_tools, ","))
  end

  local deny_tools = opts.permissions_deny
  if deny_tools and #deny_tools > 0 then
    table.insert(cmd, "--deny")
    table.insert(cmd, table.concat(deny_tools, ","))
  end

  local ask_tools = opts.permissions_ask
  if ask_tools and #ask_tools > 0 then
    table.insert(cmd, "--ask")
    table.insert(cmd, table.concat(ask_tools, ","))
  end

  -- Add permission mode: Use frontmatter only
  local permission_mode = opts.permission_mode
  if permission_mode then
    table.insert(cmd, "--permission-mode")
    table.insert(cmd, permission_mode)
  end

  -- Add permission rules: Use config only (not supported in frontmatter yet)
  local rules = self.config.permissions and self.config.permissions.rules
  if rules and #rules > 0 then
    table.insert(cmd, "--rules")
    table.insert(cmd, vim.json.encode(rules))
  end

  -- Add prioritize_vibing_lsp flag: Use config only
  local prioritize_vibing_lsp = self.config.agent and self.config.agent.prioritize_vibing_lsp
  if prioritize_vibing_lsp ~= nil then
    table.insert(cmd, "--prioritize-vibing-lsp")
    table.insert(cmd, tostring(prioritize_vibing_lsp))
  end

  -- Add mcp_enabled flag: Use config only
  local mcp_enabled = self.config.mcp and self.config.mcp.enabled
  if mcp_enabled ~= nil then
    table.insert(cmd, "--mcp-enabled")
    table.insert(cmd, tostring(mcp_enabled))
  end

  -- Add language: opts (frontmatter) > config
  local language = opts.language
  if not language and self.config.language then
    -- config.language can be a string or a table {default, chat, inline}
    if type(self.config.language) == "table" then
      -- For title generation (and other non-chat/inline uses), use default
      language = self.config.language.default or self.config.language.chat
    else
      language = self.config.language
    end
  end
  if language and type(language) == "string" then
    table.insert(cmd, "--language")
    table.insert(cmd, language)
  end

  -- Add RPC port: Get from RPC server
  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    table.insert(cmd, "--rpc-port")
    table.insert(cmd, tostring(rpc_port))
  end

  table.insert(cmd, "--prompt")
  table.insert(cmd, prompt)

  return cmd
end

---プロンプトを同期実行（ブロッキング）
---stream()を内部で呼び出し、完了まで最大2分間待機
---通常はstream()の直接使用を推奨（UIがブロックされないため）
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキスト等のオプション
---@return Vibing.Response 応答（content, error?）
function AgentSDK:execute(prompt, opts)
  opts = opts or {}
  local result = { content = "" }
  local done = false

  -- execute() はブロッキング実行なので、handle_id の管理は不要
  -- opts._session_id が指定されていればそれを使用
  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  vim.wait(120000, function() return done end, 100)
  return result
end

---プロンプトをストリーミング実行（非ブロッキング）
---Node.jsプロセスとしてagent-wrapper.mjsを起動し、JSON Lines形式で応答を受信
---session_idを自動的に保存してセッション継続を実現
---AskUserQuestionツールの双方向通信をサポート
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキスト等のオプション
---@param on_chunk fun(chunk: string) チャンク受信時のコールバック
---@param on_done fun(response: Vibing.Response) 完了時のコールバック
---@return string handle_id 生成されたハンドルID（キャンセル用）
function AgentSDK:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  -- ハンドルIDを生成（ユニークな識別子）
  local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))

  -- セッションIDの決定ロジック:
  -- 1. opts._session_id_explicit が true の場合、opts._session_id を使用（nilでも新規セッション）
  -- 2. それ以外の場合、opts._session_id を使用（後方互換性）
  local session_id
  if opts._session_id_explicit then
    -- chat.lua から明示的に設定された場合（nilでも新規セッションとして扱う）
    session_id = opts._session_id
  else
    -- inline.lua など、明示的に設定されていない場合は従来の動作
    session_id = opts._session_id
  end

  local cmd = self:build_command(prompt, opts, session_id)
  local output = {}
  local error_output = {}
  local stdout_buffer = ""

  -- vim.loop.spawn を使用して stdin への書き込みをサポート
  local stdin = vim.loop.new_pipe(false)
  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)

  local handle, pid
  local adapter = self

  -- Helper function to process JSON Lines from stdout
  local function process_stdout_line(line)
    if line == "" then return end

    local ok, msg = pcall(vim.json.decode, line)
    if not ok then return end

    if msg.type == "status" then
      if opts.status_manager then
        if msg.state == "thinking" then
          opts.status_manager:set_thinking(opts.action_type or "chat")
        elseif msg.state == "tool_use" then
          opts.status_manager:set_tool_use(msg.tool, msg.input_summary)
        elseif msg.state == "responding" then
          opts.status_manager:set_responding()
        end
      end
    elseif msg.type == "session" and msg.session_id then
      adapter._sessions[handle_id] = msg.session_id
    elseif msg.type == "tool_use" and msg.tool and msg.file_path then
      if opts.on_tool_use then
        opts.on_tool_use(msg.tool, msg.file_path)
      end
      if opts.status_manager then
        opts.status_manager:add_modified_file(msg.file_path)
      end
    elseif msg.type == "chunk" and msg.text then
      table.insert(output, msg.text)
      on_chunk(msg.text)
    elseif msg.type == "error" then
      table.insert(error_output, msg.message or "Unknown error")
    elseif msg.type == "ask_user_question" then
      -- AskUserQuestion event: show UI and send response via stdin
      adapter:_handle_ask_user_question(handle_id, msg, opts)
    end
  end

  -- Extract command and args (first element is command, rest are args)
  local spawn_cmd = cmd[1]
  local spawn_args = {}
  for i = 2, #cmd do
    table.insert(spawn_args, cmd[i])
  end

  handle, pid = vim.loop.spawn(spawn_cmd, {
    args = spawn_args,
    stdio = { stdin, stdout, stderr },
    cwd = vim.fn.getcwd(),
  }, function(code, signal)
    vim.schedule(function()
      -- Close pipes
      if stdin then stdin:close() end
      if stdout then stdout:close() end
      if stderr then stderr:close() end

      -- Cleanup
      adapter._handles[handle_id] = nil
      adapter._stdin_handles[handle_id] = nil

      if code ~= 0 or #error_output > 0 then
        on_done({
          content = table.concat(output, ""),
          error = table.concat(error_output, ""),
          _handle_id = handle_id,
        })
      else
        on_done({
          content = table.concat(output, ""),
          _handle_id = handle_id,
        })
      end
    end)
  end)

  if not handle then
    -- Cleanup pipes on spawn failure
    if stdin then stdin:close() end
    if stdout then stdout:close() end
    if stderr then stderr:close() end
    on_done({
      content = "",
      error = "Failed to spawn process",
      _handle_id = handle_id,
    })
    return handle_id
  end

  -- Store handle and stdin for later use
  self._handles[handle_id] = handle
  self._stdin_handles[handle_id] = stdin

  -- Read stdout
  stdout:read_start(function(err, data)
    if err then return end
    if not data then return end

    vim.schedule(function()
      stdout_buffer = stdout_buffer .. data
      while true do
        local newline_pos = stdout_buffer:find("\n")
        if not newline_pos then break end

        local line = stdout_buffer:sub(1, newline_pos - 1)
        stdout_buffer = stdout_buffer:sub(newline_pos + 1)
        process_stdout_line(line)
      end
    end)
  end)

  -- Read stderr
  stderr:read_start(function(err, data)
    if data then
      table.insert(error_output, data)
    end
  end)

  return handle_id
end

---AskUserQuestionイベントを処理
---UIを表示してユーザーの回答を取得し、stdinに送信
---@param handle_id string ハンドルID
---@param msg table AskUserQuestionメッセージ
---@param opts table オプション
function AgentSDK:_handle_ask_user_question(handle_id, msg, opts)
  local ask_ui = require("vibing.ui.ask_user_question")
  local questions = msg.questions or {}
  local question_id = msg.question_id
  local total_questions = #questions
  local current_index = 1
  local all_answers = {}

  local function process_next_question()
    if current_index > total_questions then
      -- All questions answered, send response
      self:_send_ask_response(handle_id, question_id, all_answers, false)
      return
    end

    local question = questions[current_index]
    local chat_buffer = opts.chat_buffer

    if not chat_buffer then
      -- No chat buffer, cancel
      self:_send_ask_response(handle_id, question_id, nil, true)
      return
    end

    ask_ui.show(chat_buffer, question, current_index, total_questions, function(answers)
      if answers == nil then
        -- User cancelled
        self:_send_ask_response(handle_id, question_id, nil, true)
        return
      end

      -- Store answer for this question
      local answer_str
      if #answers == 1 then
        answer_str = answers[1]
      else
        answer_str = table.concat(answers, ", ")
      end
      all_answers[question.question] = answer_str

      current_index = current_index + 1
      process_next_question()
    end)
  end

  process_next_question()
end

---AskUserQuestionの回答をstdinに送信
---@param handle_id string ハンドルID
---@param question_id number 質問ID
---@param answers table<string, string>? 回答（nilの場合はキャンセル）
---@param cancelled boolean キャンセルされたかどうか
function AgentSDK:_send_ask_response(handle_id, question_id, answers, cancelled)
  local stdin = self._stdin_handles[handle_id]
  if not stdin then
    return
  end

  local response = {
    type = "ask_user_question_response",
    question_id = question_id,
    cancelled = cancelled,
    answers = answers,
  }

  local json_str = vim.json.encode(response) .. "\n"
  stdin:write(json_str)
end

---実行中のリクエストをキャンセル
---Node.jsプロセスをSIGKILL(9)で強制終了
---@param handle_id string? キャンセルするハンドルID（nilの場合は全ハンドルをキャンセル）
function AgentSDK:cancel(handle_id)
  if handle_id then
    -- 特定のハンドルのみキャンセル
    local handle = self._handles[handle_id]
    if handle then
      handle:kill(9)
      self._handles[handle_id] = nil
      self._stdin_handles[handle_id] = nil
    end
  else
    -- 全ハンドルをキャンセル
    for id, handle in pairs(self._handles) do
      handle:kill(9)
      self._handles[id] = nil
      self._stdin_handles[id] = nil
    end
  end
end

---機能サポート状況を取得
---streaming, tools, context, sessionをサポート
---model_selectionは非対応（設定のdefault_modelを使用）
---@param feature string 機能名（streaming, tools, model_selection, context, session）
---@return boolean サポートしている場合true
function AgentSDK:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = false,
    context = true,
    session = true,
  }
  return features[feature] or false
end

---セッションIDを設定
---保存されたチャットファイルを開く際に、フロントマターのsession_idを設定
---次回のstream()呼び出し時に--session引数として渡される
---@param session_id string? セッションID（nilの場合は新規セッション）
---@param handle_id string? ハンドルID（nilの場合は最新のセッションIDとして保存）
function AgentSDK:set_session_id(session_id, handle_id)
  if handle_id then
    self._sessions[handle_id] = session_id
  else
    -- handle_id が指定されていない場合は、後方互換性のため特別なキーに保存
    self._sessions["__default__"] = session_id
  end
end

---セッションIDを取得
---stream()実行時に自動的に保存されたsession_idを返す
---チャットファイルのフロントマターに保存するために使用
---@param handle_id string? ハンドルID（nilの場合はデフォルトセッションIDを返す）
---@return string? セッションID（未実行の場合はnil）
function AgentSDK:get_session_id(handle_id)
  if handle_id then
    return self._sessions[handle_id]
  else
    -- handle_id が指定されていない場合は、デフォルトキーから取得
    return self._sessions["__default__"]
  end
end

---セッションIDをクリーンアップ
---get_session_id()でセッションIDを取得した後に呼び出してメモリを解放
---@param handle_id string クリーンアップするハンドルID
function AgentSDK:cleanup_session(handle_id)
  if handle_id then
    self._sessions[handle_id] = nil
  end
end

---すべての完了済みセッションをクリーンアップ
---_handlesに存在しない_sessionsエントリを削除
function AgentSDK:cleanup_stale_sessions()
  for handle_id in pairs(self._sessions) do
    -- __default__ キーと実行中のハンドルは保持
    if handle_id ~= "__default__" and not self._handles[handle_id] then
      self._sessions[handle_id] = nil
    end
  end
end

return AgentSDK
