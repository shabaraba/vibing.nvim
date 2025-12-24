---@class Vibing.AdapterOpts
---Adapterの実行オプション
---@file:path形式のコンテキスト、使用可能ツール、モデル指定、ストリーミング設定を含む
---@field context string[] @file:path形式のコンテキスト配列（例: {"@file:init.lua", "@file:config.lua:L10-L25"}）
---@field tools string[]? 許可するツールリスト（例: {"Edit", "Write", "Bash"}、nilの場合は全ツール許可）
---@field model string? モデル上書き（省略時はconfigのデフォルトモデルを使用）
---@field streaming boolean? ストリーミング応答を有効化（trueで逐次表示、falseで一括応答）

---@class Vibing.Response
---Adapterからの応答オブジェクト
---成功時はcontentに結果、失敗時はerrorにエラーメッセージが格納される
---@field content string 応答コンテンツ（Claudeの返答テキスト）
---@field error string? エラーメッセージ（実行失敗時のみ設定される）

---@class Vibing.Adapter
---AIバックエンドとの通信を抽象化するアダプター基底クラス
---agent_sdk、claude、claude_acpなど複数のバックエンドを統一インターフェースで扱う
---サブクラスはexecute(), stream(), build_command()を実装する必要がある
---@field name string アダプター名（"agent_sdk", "claude", "claude_acp"等）
---@field config Vibing.Config プラグイン設定オブジェクト（API key、モデル名等を含む）
---@field job_id number? 現在実行中のジョブID（vim.fn.jobstart()の戻り値、未実行時はnil）
local Adapter = {}
Adapter.__index = Adapter

---Adapterインスタンスを生成
---基底クラスのコンストラクタ（サブクラスでオーバーライドして使用）
---metatableを設定し、name="base"、configを保存、job_idをnilで初期化
---@param config Vibing.Config プラグイン設定オブジェクト
---@return Vibing.Adapter 新しいAdapterインスタンス
-- Create a new Adapter instance.
-- Base class constructor (subclasses should override this).
-- Sets metatable, initializes name="base", stores config, and sets job_id to nil.
-- @param config Vibing.Config Plugin configuration object.
-- @return Vibing.Adapter A new Adapter instance.
function Adapter:new(config)
  local instance = setmetatable({}, self)
  instance.name = "base"
  instance.config = config
  instance.job_id = nil
  return instance
end

---プロンプトを実行して応答を取得（非ストリーミング）
---サブクラスで実装必須のメソッド（基底クラスではエラーを投げる）
---AIバックエンドにプロンプトとオプションを送信し、完全な応答を同期的に返す
---ストリーミングが不要な場合や、完全な応答を待つ必要がある場合に使用
---@param prompt string 送信するプロンプト（ユーザーメッセージまたはシステムプロンプト）
---@param opts Vibing.AdapterOpts 実行オプション（コンテキスト、ツール、モデル等）
---@return Vibing.Response 応答オブジェクト（成功時はcontentに結果、失敗時はerrorにエラーメッセージ）
-- Execute a prompt and retrieve the response (non-streaming).
-- Subclasses must implement this method (base class throws an error).
-- Sends prompt and options to AI backend and synchronously returns the complete response.
-- Used when streaming is not needed or when a complete response is required.
-- @param prompt string The prompt to send (user message or system prompt).
-- @param opts Vibing.AdapterOpts Execution options (context, tools, model, etc.).
-- @return Vibing.Response Response object (on success, content contains result; on failure, error contains error message).
function Adapter:execute(prompt, opts)
  error("execute() must be implemented by subclass")
end

---プロンプトを実行してストリーミング応答を受信
---サブクラスで実装必須のメソッド（基底クラスではエラーを投げる）
---AIバックエンドにプロンプトとオプションを送信し、応答をチャンク単位で逐次受信
---チャットUIでの逐次表示やリアルタイムフィードバックに使用
---@param prompt string 送信するプロンプト（ユーザーメッセージまたはシステムプロンプト）
---@param opts Vibing.AdapterOpts 実行オプション（コンテキスト、ツール、モデル等）
---@param on_chunk fun(chunk: string) チャンク受信時のコールバック（テキスト断片を受け取る）
---@param on_done fun(response: Vibing.Response) 完了時のコールバック（最終応答オブジェクトを受け取る）
-- Execute a prompt and receive streaming response.
-- Subclasses must implement this method (base class throws an error).
-- Sends prompt and options to AI backend and receives response in chunks incrementally.
-- Used for incremental display in chat UI or real-time feedback.
-- @param prompt string The prompt to send (user message or system prompt).
-- @param opts Vibing.AdapterOpts Execution options (context, tools, model, etc.).
-- @param on_chunk fun(chunk: string) Callback for chunk reception (receives text fragments).
-- @param on_done fun(response: Vibing.Response) Callback for completion (receives final response object).
function Adapter:stream(prompt, opts, on_chunk, on_done)
  error("stream() must be implemented by subclass")
end

---バックエンド実行用のコマンドライン配列を構築
---サブクラスで実装必須のメソッド（基底クラスではエラーを投げる）
---vim.fn.jobstart()に渡すコマンド配列を生成（例: {"node", "bin/agent-wrapper.mjs", "--prompt", "..."}）
---プロンプト、コンテキスト、オプションをコマンドライン引数やJSON入力に変換
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション
---@return string[] コマンドライン配列（vim.fn.jobstart()の第一引数に渡す形式）
-- Build command-line array for backend execution.
-- Subclasses must implement this method (base class throws an error).
-- Generates command array to pass to vim.fn.jobstart() (e.g., {"node", "bin/agent-wrapper.mjs", "--prompt", "..."}).
-- Converts prompt, context, and options into command-line arguments or JSON input.
-- @param prompt string The prompt to send.
-- @param opts Vibing.AdapterOpts Execution options.
-- @return string[] Command-line array (format to pass as first argument to vim.fn.jobstart()).
function Adapter:build_command(prompt, opts)
  error("build_command() must be implemented by subclass")
end

---実行中のジョブをキャンセル
---job_idが設定されている場合はvim.fn.jobstop()でジョブを停止
---ストリーミング応答の中断や、長時間実行されるリクエストの強制終了に使用
---@return boolean キャンセル成功時true、実行中ジョブなしの場合false
-- Cancel a running job.
-- Stops the job with vim.fn.jobstop() if job_id is set.
-- Used for interrupting streaming responses or forcibly terminating long-running requests.
-- @return boolean True on successful cancellation, false if no running job exists.
function Adapter:cancel()
  if self.job_id then
    vim.fn.jobstop(self.job_id)
    self.job_id = nil
    return true
  end
  return false
end

---アダプターが特定の機能をサポートしているかチェック
---サブクラスでオーバーライドして機能サポートを宣言（基底クラスは常にfalse）
---"streaming", "session", "tools"等の機能名でサポート状況を問い合わせ
---呼び出し側は機能サポート状況に応じて動作を切り替える（例: ストリーミング有無）
---@param feature string 機能名（例: "streaming", "session", "tools", "cancel"）
---@return boolean サポートしている場合true、サポートしていない場合false（基底クラスは常にfalse）
-- Check if the adapter supports a specific feature.
-- Subclasses should override this to declare feature support (base class always returns false).
-- Query support status with feature names such as "streaming", "session", "tools", etc.
-- Callers switch behavior based on feature support status (e.g., streaming availability).
-- @param feature string Feature name (e.g., "streaming", "session", "tools", "cancel").
-- @return boolean True if supported, false if not supported (base class always returns false).
function Adapter:supports(feature)
  return false
end

return Adapter
