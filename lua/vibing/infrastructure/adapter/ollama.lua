---Ollama APIアダプター
---ローカルまたはリモートのOllamaサーバーと通信してAI応答を取得

local BaseAdapter = require("vibing.infrastructure.adapter.base")
local HttpClient = require("vibing.infrastructure.ollama.http_client")
local notify = require("vibing.core.utils.notify")

---@class Vibing.OllamaAdapter : Vibing.Adapter
local OllamaAdapter = setmetatable({}, { __index = BaseAdapter })
OllamaAdapter.__index = OllamaAdapter

---新しいOllamaAdapterインスタンスを作成
---@param config Vibing.Config プラグイン設定
---@return Vibing.OllamaAdapter
function OllamaAdapter:new(config)
  local instance = BaseAdapter.new(self, config)
  instance.name = "ollama"
  instance.url = config.ollama and config.ollama.url or "http://localhost:11434"
  instance.model = config.ollama and config.ollama.model or "qwen2.5-coder:0.5b"
  instance.timeout = config.ollama and config.ollama.timeout or 30000
  return instance
end

---プロンプトからコンテキストを含む完全なメッセージを構築
---@param prompt string ユーザープロンプト
---@param context string[] コンテキストファイル配列
---@return string 完全なプロンプト
function OllamaAdapter:build_prompt(prompt, context)
  if not context or #context == 0 then
    return prompt
  end

  local full_prompt = "Context:\n"
  for _, ctx in ipairs(context) do
    full_prompt = full_prompt .. ctx .. "\n"
  end
  full_prompt = full_prompt .. "\nTask:\n" .. prompt

  return full_prompt
end

---ストリーミング応答を実行
---@param prompt string プロンプト
---@param opts Vibing.AdapterOpts 実行オプション
---@param on_chunk fun(chunk: string) チャンク受信コールバック
---@param on_done fun(response: Vibing.Response) 完了コールバック
function OllamaAdapter:stream(prompt, opts, on_chunk, on_done)
  local full_prompt = self:build_prompt(prompt, opts.context or {})
  local model = opts.model or self.model

  -- 言語指定がある場合はシステムプロンプトを追加
  if opts.language == "ja" then
    full_prompt = "You are a helpful coding assistant. Please respond in Japanese only. Do not use Chinese or any other languages.\n\n" .. full_prompt
  end

  notify.info(string.format("Ollama streaming with model: %s", model), "Ollama")

  local request_body = {
    model = model,
    prompt = full_prompt,
    stream = true,
  }

  -- 接続確認
  HttpClient.check_connection(self.url, function(connected)
    if not connected then
      notify.error("Cannot connect to Ollama server at " .. self.url, "Ollama")
      if on_done then
        on_done({
          content = "",
          error = "Ollama server not reachable. Make sure it's running with 'ollama serve'",
        })
      end
      return
    end

    -- ストリーミングリクエスト開始
    local accumulated = ""

    self.job_id = HttpClient.post_stream(
      self.url .. "/api/generate",
      request_body,
      function(chunk)
        accumulated = accumulated .. chunk
        if on_chunk then
          vim.schedule(function()
            on_chunk(chunk)
          end)
        end
      end,
      function(success, data)
        if success then
          if on_done then
            on_done({
              content = accumulated,
              error = nil,
            })
          end
        else
          if on_done then
            on_done({
              content = accumulated,
              error = data.error or "Unknown error",
            })
          end
        end

        self.job_id = nil
      end
    )
  end)
end

---非ストリーミング実行（未実装）
---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function OllamaAdapter:execute(prompt, opts)
  error("OllamaAdapter:execute() is not implemented. Use stream() instead.")
end

---コマンド構築（未使用）
---@param prompt string
---@param opts Vibing.AdapterOpts
---@return string[]
function OllamaAdapter:build_command(prompt, opts)
  error("OllamaAdapter:build_command() is not used in HTTP-based implementation")
end

---機能サポートチェック
---@param feature string 機能名
---@return boolean
function OllamaAdapter:supports(feature)
  if feature == "streaming" then
    return true
  elseif feature == "cancel" then
    return true
  elseif feature == "tools" then
    return false -- Ollamaはツール実行をサポートしない
  elseif feature == "session" then
    return false -- セッション管理なし
  end
  return false
end

return OllamaAdapter
