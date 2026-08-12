---@class Vibing.StreamHandler
---Manages stdout/stderr buffering and line-by-line processing for streaming responses.
local M = {}

---stdoutコールバックを作成
---JSON Lines形式のデータを行単位でバッファリングして処理
---@param eventProcessor Vibing.EventProcessor イベント処理モジュール
---@param context table 処理コンテキスト
---@return function stdoutコールバック関数
---@param is_cancelled_fn fun(): boolean キャンセル済みかどうかを返す関数（オプション）
function M.create_stdout_handler(eventProcessor, context, is_cancelled_fn)
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
      -- キャンセル後はキューに積まれたチャンクを破棄
      if is_cancelled_fn and is_cancelled_fn() then return end

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
  local debug_mode = vim.g.vibing_debug_stream

  return function(err, data)
    if data then
      table.insert(errorOutput, data)
      -- Show stderr in debug mode
      if debug_mode then
        vim.schedule(function()
          vim.notify(string.format("[vibing:stderr] %s", data:sub(1, 200)), vim.log.levels.WARN)
        end)
      end
    end
  end
end

---プロセス終了時のコールバックを作成
---@param handleId string ハンドルID
---@param handles table<string, table> ハンドルマップ
---@param output string[] 出力バッファ
---@param errorOutput string[] エラー出力バッファ
---@param onDone fun(response: Vibing.Response) 完了コールバック
---@param get_result_errors? fun(): string[]|nil CLIが自ら「このターンは失敗」と告げた本文
---@return function 終了コールバック関数
function M.create_exit_handler(handleId, handles, output, errorOutput, onDone, get_result_errors)
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
      local stderr_text = table.concat(errorOutput, "")

      -- stderr に出力があっても、それだけでは失敗としない。
      -- CLI は正常終了(code 0)でも非致命的な警告を stderr に出すことがあり
      -- （例: codex の "failed to load models cache" 警告）、それで生成済みの
      -- stdout を握り潰すとタイトル生成などが不必要に失敗する。失敗判定は
      -- 終了コードで行い、stderr は可視化のため通知だけ残す。
      if #errorOutput > 0 then
        vim.notify(string.format("[vibing] Process stderr:\n%s", stderr_text:sub(1, 500)), vim.log.levels.WARN)
      end

      if obj.code ~= 0 then
        local error_msg = stderr_text
        if error_msg == "" then
          error_msg = "Process exited with code " .. tostring(obj.code)
        end
        onDone({
          content = table.concat(output, ""),
          error = error_msg,
          _handle_id = handleId,
        })
      else
        -- 終了コードが0でも、CLIがresultイベントでエラーを宣言していればそれは失敗。
        -- stderrと違い警告混じりではないので握り潰さない
        local result_errors = get_result_errors and get_result_errors() or nil
        onDone({
          content = table.concat(output, ""),
          error = result_errors and #result_errors > 0 and table.concat(result_errors, "\n") or nil,
          _handle_id = handleId,
        })
      end
    end)
  end
end

return M
