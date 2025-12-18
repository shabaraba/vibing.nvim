local Base = require("vibing.adapters.base")

---@class Vibing.ClaudeAdapter : Vibing.Adapter
---Claude CLIアダプター
---公式のclaude CLIツールを使用してClaudeと通信（--print, --verbose, --output-format stream-json）
---Base Adapterを継承し、ストリーミング、ツール指定、モデル選択、コンテキスト渡しをサポート
local Claude = setmetatable({}, { __index = Base })
Claude.__index = Claude

---ClaudeAdapterインスタンスを生成
---Base.new()を呼び出してベースインスタンスを作成し、name="claude"を設定
---@param config Vibing.Config プラグイン設定オブジェクト
---@return Vibing.ClaudeAdapter 新しいClaudeAdapterインスタンス
function Claude:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, Claude)
  instance.name = "claude"
  return instance
end

---claude CLIコマンドライン配列を構築
---config.cli_pathをベースに、ストリーミング、ツール、モデル、コンテキストをオプションとして追加
---最終的にプロンプトを末尾に追加してvim.systemに渡す形式で返す
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション（streaming, tools, model, context）
---@return string[] コマンドライン配列（例: {"claude", "--print", "--verbose", "--output-format", "stream-json", "@file:init.lua", "Fix this"}）
function Claude:build_command(prompt, opts)
  local cmd = { self.config.cli_path, "--print" }

  if opts.streaming then
    table.insert(cmd, "--verbose")
    table.insert(cmd, "--output-format")
    table.insert(cmd, "stream-json")
  end

  if opts.tools and #opts.tools > 0 then
    table.insert(cmd, "--tools")
    table.insert(cmd, table.concat(opts.tools, ","))
  end

  if opts.model then
    table.insert(cmd, "--model")
    table.insert(cmd, opts.model)
  end

  for _, ctx in ipairs(opts.context or {}) do
    table.insert(cmd, ctx)
  end

  table.insert(cmd, prompt)

  return cmd
end

---プロンプトを実行して応答を取得（非ストリーミング）
---streaming=falseでbuild_command()を呼び出し、vim.fn.system()で同期実行
---終了コードが0以外の場合はerrorフィールドに出力を設定、成功時はcontentに結果を設定
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション（tools, model, context等、streamingは強制的にfalse）
---@return Vibing.Response 応答オブジェクト（成功時はcontentに結果、失敗時はerrorにエラーメッセージ）
function Claude:execute(prompt, opts)
  opts = opts or {}
  opts.streaming = false
  local cmd = self:build_command(prompt, opts)
  local result = vim.fn.system(cmd)
  local exit_code = vim.v.shell_error

  if exit_code ~= 0 then
    return { content = "", error = result }
  end

  return { content = result }
end

---プロンプトを実行してストリーミング応答を受信
---streaming=trueでbuild_command()を呼び出し、vim.system()で非同期実行
---stdout を行単位でバッファリングしてJSON解析、assistant/result typeからテキストを抽出してon_chunk()に渡す
---完了時にon_done()を呼び出し、終了コードに応じてerrorまたはcontentを設定
---@param prompt string 送信するプロンプト
---@param opts Vibing.AdapterOpts 実行オプション（tools, model, context等、streamingは強制的にtrue）
---@param on_chunk fun(chunk: string) チャンク受信時のコールバック（テキスト断片を受け取る）
---@param on_done fun(response: Vibing.Response) 完了時のコールバック（最終応答オブジェクトを受け取る）
function Claude:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}
  opts.streaming = true
  local cmd = self:build_command(prompt, opts)
  local output = {}
  local error_output = {}
  local stdout_buffer = ""

  local handle = vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err then return end
      if not data then return end

      -- バッファリング処理（行境界で分割）
      stdout_buffer = stdout_buffer .. data
      while true do
        local newline_pos = stdout_buffer:find("\n")
        if not newline_pos then break end

        local line = stdout_buffer:sub(1, newline_pos - 1)
        stdout_buffer = stdout_buffer:sub(newline_pos + 1)

        if line ~= "" then
          local ok, json = pcall(vim.json.decode, line)
          if ok then
            vim.schedule(function()
              -- assistant メッセージからテキストを抽出
              if json.type == "assistant" and json.message and json.message.content then
                for _, content in ipairs(json.message.content) do
                  if content.type == "text" and content.text then
                    table.insert(output, content.text)
                    on_chunk(content.text)
                  end
                end
              elseif json.type == "result" and json.result then
                if #output == 0 then
                  table.insert(output, json.result)
                  on_chunk(json.result)
                end
              end
            end)
          end
        end
      end
    end,
    stderr = function(err, data)
      if data then
        table.insert(error_output, data)
      end
    end,
  }, function(obj)
    vim.schedule(function()
      self._handle = nil
      if obj.code ~= 0 then
        on_done({ content = "", error = table.concat(error_output, "") })
      else
        on_done({ content = table.concat(output, "") })
      end
    end)
  end)

  self._handle = handle
end

---アダプターが特定の機能をサポートしているかチェック
---ClaudeAdapterはstreaming, tools, model_selection, contextをサポート
---呼び出し側は機能サポート状況に応じて動作を切り替える
---@param feature string 機能名（"streaming", "tools", "model_selection", "context"）
---@return boolean サポートしている場合true、サポートしていない場合false
function Claude:supports(feature)
  local features = {
    streaming = true,
    tools = true,
    model_selection = true,
    context = true,
  }
  return features[feature] or false
end

return Claude
