---@class Vibing.StreamHandler
---Manages stdout/stderr buffering and line-by-line processing for streaming responses.
local M = {}

---stdoutコールバックを作成
---JSON Lines形式のデータを行単位でバッファリングして処理
---@param event_processor Vibing.EventProcessor イベント処理モジュール
---@param context table 処理コンテキスト
---@return function stdoutコールバック関数
function M.create_stdout_handler(event_processor, context)
  local stdout_buffer = ""

  return function(err, data)
    if err then return end
    if not data then return end

    vim.schedule(function()
      -- Buffer and process line by line
      stdout_buffer = stdout_buffer .. data
      while true do
        local newline_pos = stdout_buffer:find("\n")
        if not newline_pos then break end

        local line = stdout_buffer:sub(1, newline_pos - 1)
        stdout_buffer = stdout_buffer:sub(newline_pos + 1)

        event_processor.process_line(line, context)
      end
    end)
  end
end

---stderrコールバックを作成
---エラー出力をバッファに追加
---@param error_output string[] エラー出力バッファ
---@return function stderrコールバック関数
function M.create_stderr_handler(error_output)
  return function(err, data)
    if data then
      table.insert(error_output, data)
    end
  end
end

---プロセス終了時のコールバックを作成
---@param handle_id string ハンドルID
---@param handles table<string, table> ハンドルマップ
---@param output string[] 出力バッファ
---@param error_output string[] エラー出力バッファ
---@param on_done fun(response: Vibing.Response) 完了コールバック
---@return function 終了コールバック関数
function M.create_exit_handler(handle_id, handles, output, error_output, on_done)
  return function(obj)
    vim.schedule(function()
      -- クリーンアップ：ハンドルをマップから削除（セッションIDは保持）
      handles[handle_id] = nil

      -- on_done は常に呼び出される（エラー時も正常終了時も）
      -- これによりキューがブロックされるのを防ぐ
      if obj.code ~= 0 or #error_output > 0 then
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
  end
end

return M
