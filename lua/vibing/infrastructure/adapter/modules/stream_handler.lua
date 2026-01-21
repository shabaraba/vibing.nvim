---@class Vibing.StreamHandler
---Manages stdout/stderr buffering and line-by-line processing for streaming responses.
local M = {}

---stdoutコールバックを作成
---JSON Lines形式のデータを行単位でバッファリングして処理
---@param eventProcessor Vibing.EventProcessor イベント処理モジュール
---@param context table 処理コンテキスト
---@return function stdoutコールバック関数
function M.create_stdout_handler(eventProcessor, context)
  local stdoutBuffer = ""
  local debug_mode = vim.g.vibing_debug_stream

  return function(err, data)
    if debug_mode then
      vim.schedule(function()
        vim.notify(string.format("[vibing:stream] stdout callback: err=%s, data=%s",
          tostring(err), data and (#data .. " bytes") or "nil"), vim.log.levels.DEBUG)
      end)
    end

    if err then return end
    if not data then return end

    vim.schedule(function()
      if debug_mode then
        vim.notify("[vibing:stream] vim.schedule executed", vim.log.levels.DEBUG)
      end

      -- Buffer and process line by line
      stdoutBuffer = stdoutBuffer .. data
      while true do
        local newlinePos = stdoutBuffer:find("\n")
        if not newlinePos then break end

        local line = stdoutBuffer:sub(1, newlinePos - 1)
        stdoutBuffer = stdoutBuffer:sub(newlinePos + 1)

        if debug_mode then
          vim.notify(string.format("[vibing:stream] processing line: %s", line:sub(1, 80)), vim.log.levels.DEBUG)
        end

        eventProcessor.processLine(line, context)
      end
    end)
  end
end

---stderrコールバックを作成
---エラー出力をバッファに追加
---@param errorOutput string[] エラー出力バッファ
---@return function stderrコールバック関数
function M.create_stderr_handler(errorOutput)
  return function(err, data)
    if data then
      table.insert(errorOutput, data)
    end
  end
end

---プロセス終了時のコールバックを作成
---@param handleId string ハンドルID
---@param handles table<string, table> ハンドルマップ
---@param output string[] 出力バッファ
---@param errorOutput string[] エラー出力バッファ
---@param onDone fun(response: Vibing.Response) 完了コールバック
---@return function 終了コールバック関数
function M.create_exit_handler(handleId, handles, output, errorOutput, onDone)
  local debug_mode = vim.g.vibing_debug_stream

  return function(obj)
    if debug_mode then
      vim.schedule(function()
        vim.notify(string.format("[vibing:stream] Process exited: code=%s, signal=%s",
          tostring(obj.code), tostring(obj.signal)), vim.log.levels.INFO)
      end)
    end

    vim.schedule(function()
      -- クリーンアップ：ハンドルをマップから削除（セッションIDは保持）
      handles[handleId] = nil

      -- onDone は常に呼び出される（エラー時も正常終了時も）
      -- これによりキューがブロックされるのを防ぐ
      if obj.code ~= 0 or #errorOutput > 0 then
        local error_msg = table.concat(errorOutput, "")
        if error_msg == "" and obj.code ~= 0 then
          error_msg = "Claude Code process exited with code " .. obj.code
        end
        onDone({
          content = table.concat(output, ""),
          error = error_msg,
          _handle_id = handleId,
        })
      else
        onDone({
          content = table.concat(output, ""),
          _handle_id = handleId,
        })
      end
    end)
  end
end

return M
