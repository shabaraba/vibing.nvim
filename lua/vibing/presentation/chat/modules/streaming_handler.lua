local Timestamp = require("vibing.core.utils.timestamp")

local M = {}

---アシスタント応答を開始
---
---ヘッダーには時刻を入れない。ここで分かるのはターンの**開始**時刻だが、記録して意味が
---あるのは最後のAPIリクエストが飛んだ時刻＝ターンの終わりなので、それは
---`M.stamp_response_end` が完了時に書き込む
---@param buf number バッファ番号
---@return number header_line 書いた `## Assistant` の行番号（1始まり）
function M.start_response(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines, #lines)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  local new_lines = {
    "",
    "## Assistant",
    "",
  }
  vim.api.nvim_buf_set_lines(buf, #lines, #lines, false, new_lines)
  return #lines + 2
end

---ターン完了時に `## Assistant` へ終了時刻を書き込む
---
---これがプロンプトキャッシュの生死を判定する唯一の材料になる（`application/chat/cache_expiry`）。
---直前の `## User` の時刻ではターンの所要時間ぶん古く、長いターンほどずれが大きい。
---
---触るのは `start_response` が返した行だけ。ターン中に足されるものはすべて末尾への追記なので
---この行番号は動かない。**末尾から「ヘッダーに見える行」を探してはいけない**: `parse_header`
---のレガシー分岐は列0の素の `## Assistant` をどこでも拾うので、チャット書式そのものを説明した
---返答（このリポジトリの README がまさにそう）が本文に書いた行を書き換えてしまい、transcript
---を壊したうえで本物のヘッダーには時刻が入らない。
---
---行が範囲外だったり素の `## Assistant` でなくなっていたら何もしない。時刻が入らなければ
---期限切れ判定が出なくなるだけで、transcript を壊すよりはるかに軽い
---@param buf number バッファ番号
---@param header_line number? `start_response` が返した行番号（1始まり）
function M.stamp_response_end(buf, header_line)
  if not vim.api.nvim_buf_is_valid(buf) or type(header_line) ~= "number" then
    return
  end

  if vim.api.nvim_buf_get_lines(buf, header_line - 1, header_line, false)[1] ~= "## Assistant" then
    return
  end

  local stamped = Timestamp.create_header("Assistant", Timestamp.now())
  vim.api.nvim_buf_set_lines(buf, header_line - 1, header_line, false, { stamped })
end

---バッファリングされたチャンクをフラッシュ
---@param buf number バッファ番号
---@param win number? ウィンドウ番号
---@param chunk_buffer string バッファリング内容
---@return string empty_string 空文字列（バッファクリア用）
function M.flush_chunks(buf, win, chunk_buffer)
  if not vim.api.nvim_buf_is_valid(buf) or chunk_buffer == "" then
    return ""
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last_line = lines[#lines] or ""

  -- ヘッダー直後の空行に続く先頭改行を除去（余分な空行防止）
  if last_line == "" and chunk_buffer:sub(1, 1) == "\n" then
    chunk_buffer = chunk_buffer:gsub("^\n+", "")
  end

  local chunk_lines = vim.split(chunk_buffer, "\n", { plain = true })
  chunk_lines[1] = last_line .. chunk_lines[1]

  vim.api.nvim_buf_set_lines(buf, #lines - 1, #lines, false, chunk_lines)

  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      local current_line = cursor[1]
      local old_line_count = #lines

      if current_line >= old_line_count then
        local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local line_count = #new_lines
        if line_count > 0 then
          pcall(vim.api.nvim_win_set_cursor, win, { line_count, 0 })
        end
      end
    end
  end

  return ""
end

return M
