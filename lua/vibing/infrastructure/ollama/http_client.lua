---Ollama HTTP通信クライアント
---curlを使用してOllama APIと通信

local M = {}

---Ollama APIにPOSTリクエストを送信
---@param url string リクエストURL
---@param body table リクエストボディ（Luaテーブル）
---@param on_chunk fun(chunk: string)? ストリーミングチャンクのコールバック
---@param on_done fun(success: boolean, data: string|table) 完了コールバック
---@return number job_id vim.fn.jobstart()のジョブID
function M.post_stream(url, body, on_chunk, on_done)
  local json_body = vim.json.encode(body)
  local buffer = ""
  local stderr_buffer = ""

  local job_id = vim.fn.jobstart({
    "curl",
    "-X", "POST",
    "-H", "Content-Type: application/json",
    "-d", json_body,
    url,
    "--no-buffer", -- ストリーミング用
    "--silent",
    "--show-error",
  }, {
    on_stdout = function(_, data, _)
      if not data then
        return
      end

      for _, line in ipairs(data) do
        if line ~= "" then
          buffer = buffer .. line

          -- JSON Lines形式でパース（改行区切り）
          local newline_pos = buffer:find("\n")
          while newline_pos do
            local json_line = buffer:sub(1, newline_pos - 1)
            buffer = buffer:sub(newline_pos + 1)

            -- JSONをデコード
            local ok, decoded = pcall(vim.json.decode, json_line)
            if ok and decoded then
              -- responseフィールドからテキストを抽出
              if decoded.response then
                if on_chunk then
                  on_chunk(decoded.response)
                end
              end

              -- 完了チェック
              if decoded.done then
                if on_done then
                  vim.schedule(function()
                    on_done(true, decoded)
                  end)
                end
              end
            end

            newline_pos = buffer:find("\n")
          end
        end
      end
    end,

    on_stderr = function(_, data, _)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            stderr_buffer = stderr_buffer .. line .. "\n"
          end
        end
      end
    end,

    on_exit = function(_, exit_code, _)
      if exit_code ~= 0 then
        if on_done then
          vim.schedule(function()
            on_done(false, {
              error = "HTTP request failed",
              details = stderr_buffer,
              exit_code = exit_code,
            })
          end)
        end
      end
    end,
  })

  return job_id
end

---Ollama APIの接続確認
---@param url string OllamaベースURL（例: "http://localhost:11434"）
---@param callback fun(success: boolean)
function M.check_connection(url, callback)
  local tags_url = url .. "/api/tags"

  vim.fn.jobstart({
    "curl",
    "-s",
    "-f", -- HTTPエラーでexit codeを返す
    tags_url,
  }, {
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        callback(exit_code == 0)
      end)
    end,
  })
end

return M
