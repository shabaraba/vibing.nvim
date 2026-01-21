local Base = require("vibing.infrastructure.adapter.base")
local CommandBuilder = require("vibing.infrastructure.adapter.modules.command_builder")
local EventProcessor = require("vibing.infrastructure.adapter.modules.event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")

---@class Vibing.AgentSDKAdapter : Vibing.Adapter
---@field _handles table<string, table> vim.system()で起動したプロセスハンドルのマップ（handle_id -> handle）
---@field _session_manager table セッション管理インスタンス
---@field _plugin_root string プラグインのルートディレクトリパス
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
  instance._session_manager = SessionManagerModule.new()
  -- Find plugin root directory
  local source = debug.getinfo(1, "S").source:sub(2)
  instance._plugin_root = vim.fn.fnamemodify(source, ":h:h:h:h:h")
  -- Initialize random seed for handle ID generation
  math.randomseed(vim.loop.hrtime())
  return instance
end

---ラッパースクリプトのパスを取得
---dev_modeがtrueの場合はbin/agent-wrapper.ts（TypeScript）を返す
---dev_modeがfalseの場合はdist/bin/agent-wrapper.js（コンパイル済み）を返す
---ファイルの存在を確認し、存在しない場合はエラーを通知
---@return string ラッパースクリプトの絶対パス
function AgentSDK:get_wrapper_path()
  local dev_mode = self.config.node and self.config.node.dev_mode or false

  local wrapper_path
  if dev_mode then
    -- Development mode: use TypeScript directly
    wrapper_path = self._plugin_root .. "/bin/agent-wrapper.ts"
    if vim.fn.filereadable(wrapper_path) ~= 1 then
      local error_msg = string.format(
        "[vibing.nvim] Error: Agent wrapper (TypeScript) not found at '%s'.\n" ..
        "Please ensure the source file exists.",
        wrapper_path
      )
      vim.notify(error_msg, vim.log.levels.ERROR)
      error(string.format("Agent wrapper (TypeScript) not found: %s", wrapper_path))
    end
  else
    -- Production mode: use compiled JavaScript
    wrapper_path = self._plugin_root .. "/dist/bin/agent-wrapper.js"
    if vim.fn.filereadable(wrapper_path) ~= 1 then
      local error_msg = string.format(
        "[vibing.nvim] Error: Agent wrapper not found at '%s'.\n" ..
        "Please build the plugin by running: npm install && npm run build\n" ..
        "Or if using Lazy.nvim, ensure the 'build' hook is configured: build = \"./build.sh\"",
        wrapper_path
      )
      vim.notify(error_msg, vim.log.levels.ERROR)
      error(string.format("Agent wrapper not found: %s", wrapper_path))
    end
  end

  return wrapper_path
end

---コマンドライン引数を構築
---Node.jsラッパースクリプトの実行コマンドを生成
---mode, model, context, session, permissionsを設定から反映
---opts内の値はfrontmatterから渡され、グローバル設定より優先される
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキストファイル等のオプション
---@param session_id string? セッションID（nilの場合は新規セッション）
---@return string[] コマンドと引数の配列
function AgentSDK:build_command(prompt, opts, session_id)
  return CommandBuilder.build(self:get_wrapper_path(), prompt, opts, session_id, self.config)
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
---@param prompt string ユーザープロンプト
---@param opts Vibing.AdapterOpts コンテキスト等のオプション
---@param on_chunk fun(chunk: string) チャンク受信時のコールバック
---@param on_done fun(response: Vibing.Response) 完了時のコールバック
---@return string handle_id 生成されたハンドルID（キャンセル用）
-- 初回応答タイムアウト（ミリ秒）
local INITIAL_RESPONSE_TIMEOUT_MS = 120000

function AgentSDK:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream

  -- ハンドルIDを生成（ユニークな識別子）
  local handle_id = tostring(vim.loop.hrtime()) .. "_" .. tostring(math.random(100000))

  -- セッションIDの取得
  -- opts._session_id が nil の場合は新規セッションとして扱う
  local session_id = opts._session_id

  if debug_mode then
    -- Check existing handles
    local handle_count = 0
    for _ in pairs(self._handles) do handle_count = handle_count + 1 end
    vim.notify(string.format("[vibing:stream] Starting stream: handle_id=%s, session_id=%s, existing_handles=%d",
      handle_id, session_id or "new", handle_count), vim.log.levels.INFO)
  end

  local cmd = self:build_command(prompt, opts, session_id)
  local output = {}
  local error_output = {}

  -- 初回応答フラグ（タイムアウト用）
  local received_first_response = false
  local timeout_timer = nil

  -- イベント処理コンテキストを構築
  local eventContext = {
    sessionManager = self._session_manager,
    handleId = handle_id,
    opts = opts,
    output = output,
    errorOutput = error_output,
    onChunk = function(chunk)
      received_first_response = true
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
      on_chunk(chunk)
    end,
  }

  -- Build environment with optional debug flags
  local env = vim.fn.environ()
  if vim.g.vibing_skip_plugins then
    env.VIBING_SKIP_PLUGINS = "1"
  end

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    env = env,
    stdout = StreamHandler.create_stdout_handler(EventProcessor, eventContext),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, on_done))

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:stream] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    -- Log command for debugging
    vim.notify(string.format("[vibing:stream] Command: %s", table.concat(cmd, " "):sub(1, 200)), vim.log.levels.DEBUG)
  end

  -- Lua側ウォッチドッグタイマー（Node.jsがCPUブロックしても効く）
  if session_id then
    timeout_timer = vim.fn.timer_start(INITIAL_RESPONSE_TIMEOUT_MS, function()
      if not received_first_response and self._handles[handle_id] then
        vim.schedule(function()
          vim.notify(
            "[vibing] Session resume timeout - killing hung process and resetting session",
            vim.log.levels.WARN
          )
          self:cancel(handle_id)
          -- session_corruptedイベントを手動で発行
          on_done({
            error = "Session resume timeout",
            _session_corrupted = true,
            _old_session_id = session_id,
          })
        end)
      end
    end)
  end

  -- ハンドルIDを返す（キャンセル用）
  return handle_id
end

---実行中のリクエストをキャンセル
---Node.jsプロセスをSIGKILL(9)で強制終了
---@param handle_id string? キャンセルするハンドルID（nilの場合は全ハンドルをキャンセル）
function AgentSDK:cancel(handle_id)
  if handle_id then
    -- 特定のハンドルのみキャンセル
    local handle = self._handles[handle_id]
    if handle then
      pcall(function()
        if handle.pid and handle.pid > 0 then
          handle:kill(9)
        end
      end)
      self._handles[handle_id] = nil
    end
  else
    -- 全ハンドルをキャンセル
    for id, handle in pairs(self._handles) do
      pcall(function()
        if handle.pid and handle.pid > 0 then
          handle:kill(9)
        end
      end)
      self._handles[id] = nil
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
  SessionManagerModule.set(self._session_manager, session_id, handle_id)
end

---セッションIDを取得
---stream()実行時に自動的に保存されたsession_idを返す
---チャットファイルのフロントマターに保存するために使用
---@param handle_id string? ハンドルID（nilの場合はデフォルトセッションIDを返す）
---@return string? セッションID（未実行の場合はnil）
function AgentSDK:get_session_id(handle_id)
  return SessionManagerModule.get(self._session_manager, handle_id)
end

---セッションIDをクリーンアップ
---get_session_id()でセッションIDを取得した後に呼び出してメモリを解放
---@param handle_id string クリーンアップするハンドルID
function AgentSDK:cleanup_session(handle_id)
  SessionManagerModule.cleanup(self._session_manager, handle_id)
end

---すべての完了済みセッションをクリーンアップ
---_handlesに存在しない_sessionsエントリを削除
function AgentSDK:cleanup_stale_sessions()
  SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
end

return AgentSDK
