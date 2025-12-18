local notify = require("vibing.utils.notify")

---/summarizeコマンドハンドラー
---チャット内で/summarizeを実行した際に呼び出される
---現在の会話履歴をClaudeに要約させ、フローティングウィンドウで表示
---会話履歴は[role]: content形式でClaudeに送信され、要約プロンプトが追加される
---要約結果はMarkdown形式で読み取り専用バッファに表示（qキーで閉じる）
---@param _ string[] コマンド引数（このハンドラーでは未使用）
---@param chat_buffer Vibing.ChatBuffer コマンドを実行したチャットバッファ
---@return boolean 要約リクエストを送信した場合true、バッファ無効や会話なしの場合false
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return false
  end

  -- 会話履歴を抽出
  local conversation = chat_buffer:extract_conversation()

  if #conversation == 0 then
    notify.warn("No conversation to summarize")
    return false
  end

  -- 要約プロンプトを作成
  local summary_prompt = "Please summarize the above conversation in a concise manner, highlighting key points and decisions."

  -- 会話履歴を文字列に変換
  local conversation_text = {}
  for _, msg in ipairs(conversation) do
    table.insert(conversation_text, string.format("[%s]: %s", msg.role, msg.content))
  end

  local full_prompt = table.concat(conversation_text, "\n\n") .. "\n\n" .. summary_prompt

  -- アダプターを取得して要約をリクエスト
  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured")
    return false
  end

  notify.info("Generating summary...")

  -- 要約を非同期で取得
  adapter:stream(full_prompt, {}, function(chunk)
    -- チャンクを無視（ストリーミングは表示しない）
  end, function(response)
    if response.error then
      notify.error(string.format("Summarization failed: %s", response.error))
      return
    end

    -- 要約結果を表示
    local summary = response.content
    if summary and summary ~= "" then
      -- 浮動ウィンドウで要約を表示
      local lines = vim.split(summary, "\n", { plain = true })
      local width = 80
      local height = math.min(#lines + 2, 20)

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].filetype = "markdown"

      local win = vim.api.nvim_open_win(buf, true, {
        relative = "editor",
        width = width,
        height = height,
        row = math.floor((vim.o.lines - height) / 2),
        col = math.floor((vim.o.columns - width) / 2),
        style = "minimal",
        border = "rounded",
        title = " Summary ",
        title_pos = "center",
      })

      -- qで閉じる
      vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
      end, { buffer = buf, nowait = true })

      notify.info("Summary generated (press 'q' to close)")
    end
  end)

  return true
end
