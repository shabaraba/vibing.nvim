local Base = require("vibing.adapters.base")

---@class Vibing.ClaudeACPAdapter : Vibing.Adapter
---Claude ACPアダプター（Agent Communication Protocol）
---JSON-RPCプロトコルを使用してclaude-code-acpプロセスと通信
---セッション管理、リソースブロック、ストリーミング応答をサポート
---Base Adapterを継承し、永続的なセッションと双方向通信を実現
---@field _handle table? vim.system()のプロセスハンドル
---@field _state { next_id: number, stdout_buffer: string, pending: table, session_id: string? } 内部状態（RPC ID管理、バッファ、コールバック、セッションID）
local ClaudeACP = setmetatable({}, { __index = Base })
ClaudeACP.__index = ClaudeACP

local METHODS = {
  INITIALIZE = "initialize",
  SESSION_NEW = "session/new",
  SESSION_PROMPT = "session/prompt",
  SESSION_CANCEL = "session/cancel",
  SESSION_UPDATE = "session/update",
}

---ClaudeACPAdapterインスタンスを生成
---Base.new()を呼び出してベースインスタンスを作成し、name="claude_acp"を設定
---_handle=nil、_state（next_id=1、空バッファ、空pending、セッションIDなし）で初期化
---@param config Vibing.Config プラグイン設定オブジェクト
---@return Vibing.ClaudeACPAdapter 新しいClaudeACPAdapterインスタンス
function ClaudeACP:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, ClaudeACP)
  instance.name = "claude_acp"
  instance._handle = nil
  instance._state = {
    next_id = 1,
    stdout_buffer = "",
    pending = {},
    session_id = nil,
  }
  return instance
end

---claude-code-acpコマンドライン配列を構築
---固定で{"claude-code-acp"}を返す（オプションなし）
---@return string[] コマンドライン配列（常に {"claude-code-acp"}）
function ClaudeACP:build_command()
  return { "claude-code-acp" }
end

---JSON-RPCリクエストメッセージを送信
---JSON-RPC 2.0形式でID付きリクエストを送信し、コールバックをpendingに登録
---応答受信時にhandle_rpc_message()からコールバックが呼び出される
---@param method string JSON-RPCメソッド名（"initialize", "session/new", "session/prompt"等）
---@param params table? メソッドパラメータ（省略可）
---@param callback fun(result: table?, error: table?)? 応答受信時のコールバック（result またはerrorのいずれかが設定される）
function ClaudeACP:send_rpc(method, params, callback)
  if not self._handle then return end

  local id = self._state.next_id
  self._state.next_id = id + 1

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or {},
  }) .. "\n"

  if callback then
    self._state.pending[id] = callback
  end

  self._handle:write(msg)
  return id
end

---JSON-RPC通知メッセージを送信（応答なし）
---JSON-RPC 2.0形式でID なし通知を送信（応答を期待しない一方向メッセージ）
---session/cancelなど、応答不要の操作に使用
---@param method string JSON-RPCメソッド名（"session/cancel"等）
---@param params table? メソッドパラメータ（省略可）
function ClaudeACP:send_notification(method, params)
  if not self._handle then return end

  local msg = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or {},
  }) .. "\n"

  self._handle:write(msg)
end

---stdout データを行単位でバッファリングして処理
---改行区切りでJSON-RPCメッセージを分割し、各行をJSON解析してhandle_rpc_message()に渡す
---不完全な行はstdout_bufferに保持され、次回のデータ受信時に結合される
---@param data string 受信した標準出力データ
---@param on_chunk fun(chunk: string) agent_message_chunkイベント発生時に呼び出されるコールバック
function ClaudeACP:handle_stdout(data, on_chunk)
  self._state.stdout_buffer = self._state.stdout_buffer .. data

  while true do
    local newline_pos = self._state.stdout_buffer:find("\n")
    if not newline_pos then break end

    local line = self._state.stdout_buffer:sub(1, newline_pos - 1):gsub("\r$", "")
    self._state.stdout_buffer = self._state.stdout_buffer:sub(newline_pos + 1)

    if line ~= "" and line:match("^%s*{") then
      local ok, msg = pcall(vim.json.decode, line)
      if ok then
        self:handle_rpc_message(msg, on_chunk)
      end
    end
  end
end

---JSON-RPCメッセージを処理
---応答（ID付き、methodなし）の場合はpendingコールバックを呼び出し
---通知（methodあり）の場合はsession/updateイベントを処理してagent_message_chunkからテキストを抽出
---@param msg table JSON解析済みのRPCメッセージ
---@param on_chunk fun(chunk: string) agent_message_chunk受信時に呼び出されるコールバック
function ClaudeACP:handle_rpc_message(msg, on_chunk)
  -- Response to our request
  if msg.id and not msg.method then
    vim.notify("[ACP] Response id=" .. msg.id, vim.log.levels.DEBUG)
    local callback = self._state.pending[msg.id]
    if callback then
      self._state.pending[msg.id] = nil
      if msg.error then
        vim.notify("[ACP] Error: " .. vim.inspect(msg.error), vim.log.levels.ERROR)
        callback(nil, msg.error)
      else
        callback(msg.result, nil)
      end
    end
    return
  end

  -- Notification from server
  if msg.method == METHODS.SESSION_UPDATE and msg.params then
    local update = msg.params.update
    if update then
      local update_type = update.sessionUpdate or "unknown"
      vim.notify("[ACP] Update: " .. update_type, vim.log.levels.DEBUG)
      if update_type == "agent_message_chunk" then
        local content = update.content
        if content and content.type == "text" and content.text then
          vim.notify("[ACP] Chunk: " .. content.text:sub(1, 50), vim.log.levels.INFO)
          on_chunk(content.text)
        end
      end
    end
  end
end

---ACPプロセスを起動してセッションを初期化
---vim.system()でclaude-code-acpを起動し、initializeとsession/newを順次実行
---初期化成功時にon_ready(true)を呼び出し、session_idを_stateに保存
---プロセス終了時にon_done()を呼び出す
---@param on_ready fun(success: boolean) 初期化完了時のコールバック（成功/失敗を受け取る）
---@param on_chunk fun(chunk: string) agent_message_chunk受信時のコールバック
---@param on_done fun(response: Vibing.Response) プロセス終了時のコールバック
function ClaudeACP:start(on_ready, on_chunk, on_done)
  if self._handle then
    on_ready(true)
    return
  end

  local cmd = self:build_command()
  self._state.stdout_buffer = ""
  self._state.pending = {}

  self._handle = vim.system(cmd, {
    stdin = true,
    stdout = function(err, data)
      if err then return end
      if data then
        vim.schedule(function()
          self:handle_stdout(data, on_chunk)
        end)
      end
    end,
    stderr = function(err, data)
      if data then
        vim.schedule(function()
          vim.notify("[vibing] ACP stderr: " .. data, vim.log.levels.DEBUG)
        end)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      self._state.session_id = nil
      on_done({ content = "", error = obj.code ~= 0 and "Process exited" or nil })
    end)
  end)

  -- Initialize
  self:send_rpc(METHODS.INITIALIZE, {
    protocolVersion = 1,
    clientCapabilities = {
      fs = { readTextFile = true, writeTextFile = true },
    },
    clientInfo = {
      name = "vibing.nvim",
      version = "1.0.0",
    },
  }, function(result, err)
    if err then
      on_ready(false)
      return
    end

    -- Create session
    self:send_rpc(METHODS.SESSION_NEW, {
      cwd = vim.fn.getcwd(),
      mcpServers = {},
    }, function(session_result, session_err)
      if session_err or not session_result or not session_result.sessionId then
        on_ready(false)
        return
      end
      self._state.session_id = session_result.sessionId
      on_ready(true)
    end)
  end)
end

---プロンプトを実行して応答を取得（非ストリーミング）
---ACPはストリーミング専用のため、内部的にstream()を呼び出してブロッキング待機
---vim.wait()で最大60秒間完了を待つ
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション（context等）
---@return Vibing.Response 応答オブジェクト（成功時はcontentに結果、失敗時はerrorにエラーメッセージ）
function ClaudeACP:execute(prompt, opts)
  -- ACP is streaming-only, use stream internally
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  -- Wait for completion (blocking)
  vim.wait(60000, function() return done end, 100)
  return result
end

---プロンプトを実行してストリーミング応答を受信
---既存セッション再利用または新規start()を呼び出し、session/promptでプロンプト送信
---コンテキストファイル(@file:path)をresourceブロックとして追加、プロンプトをtextブロックとして追加
---agent_message_chunkイベントでon_chunk()を呼び出し、完了時にon_done()を呼び出す
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション（context等）
---@param on_chunk fun(chunk: string) チャンク受信時のコールバック（テキスト断片を受け取る）
---@param on_done fun(response: Vibing.Response) 完了時のコールバック（最終応答オブジェクトを受け取る）
function ClaudeACP:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  local output = {}

  local function do_prompt()
    -- Build prompt content blocks (ACP format: array of content blocks, no role)
    local prompt_blocks = {}

    -- Add context files as resource blocks
    for _, ctx in ipairs(opts.context or {}) do
      if ctx:match("^@file:") then
        local path = ctx:sub(7)
        local ok, content = pcall(function()
          return table.concat(vim.fn.readfile(path), "\n")
        end)
        if ok and content then
          table.insert(prompt_blocks, {
            type = "resource",
            resource = {
              uri = "file://" .. path,
              text = content,
            },
          })
        end
      end
    end

    -- Add user prompt as text block
    table.insert(prompt_blocks, {
      type = "text",
      text = prompt,
    })

    self:send_rpc(METHODS.SESSION_PROMPT, {
      sessionId = self._state.session_id,
      prompt = prompt_blocks,
    }, function(result, err)
      if err then
        on_done({ content = table.concat(output, ""), error = err.message or "Unknown error" })
      else
        on_done({ content = table.concat(output, "") })
      end
    end)
  end

  -- Wrap on_chunk to collect output
  local wrapped_on_chunk = function(chunk)
    table.insert(output, chunk)
    on_chunk(chunk)
  end

  -- Start or reuse connection
  if self._handle and self._state.session_id then
    -- Reuse existing session - update on_chunk handler
    self._current_on_chunk = wrapped_on_chunk
    do_prompt()
  else
    self._current_on_chunk = wrapped_on_chunk
    self:start(function(success)
      if not success then
        on_done({ content = "", error = "Failed to start ACP" })
        return
      end
      do_prompt()
    end, function(chunk)
      -- Delegate to current handler
      if self._current_on_chunk then
        self._current_on_chunk(chunk)
      end
    end, on_done)
  end
end

---実行中のプロンプトをキャンセル
---session/cancel通知をACPプロセスに送信（応答なし）
---セッションIDが存在する場合のみ実行
function ClaudeACP:cancel()
  if self._handle and self._state.session_id then
    self:send_notification(METHODS.SESSION_CANCEL, {
      sessionId = self._state.session_id,
    })
  end
end

---アダプターが特定の機能をサポートしているかチェック
---ClaudeACPAdapterはstreaming, tools, contextをサポート（model_selectionは非サポート）
---呼び出し側は機能サポート状況に応じて動作を切り替える
---@param feature string 機能名（"streaming", "tools", "model_selection", "context"）
---@return boolean サポートしている場合true、サポートしていない場合false
function ClaudeACP:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = false,
    context = true,
  }
  return features[feature] or false
end

return ClaudeACP
