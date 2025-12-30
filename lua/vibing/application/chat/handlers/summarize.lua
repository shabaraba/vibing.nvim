local notify = require("vibing.core.utils.notify")

---@param _ string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(_, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return false
  end

  local conversation = chat_buffer:extract_conversation()

  if #conversation == 0 then
    notify.warn("No conversation to summarize")
    return false
  end

  local summary_prompt = "Please summarize the above conversation in a concise manner, highlighting key points and decisions."

  local conversation_text = {}
  for _, msg in ipairs(conversation) do
    table.insert(conversation_text, string.format("[%s]: %s", msg.role, msg.content))
  end

  local full_prompt = table.concat(conversation_text, "\n\n") .. "\n\n" .. summary_prompt

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()

  if not adapter then
    notify.error("No adapter configured")
    return false
  end

  notify.info("Generating summary...")

  adapter:stream(full_prompt, {}, function(chunk)
  end, function(response)
    if response.error then
      notify.error(string.format("Summarization failed: %s", response.error))
      return
    end

    local summary = response.content
    if summary and summary ~= "" then
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

      vim.keymap.set("n", "q", function()
        vim.api.nvim_win_close(win, true)
      end, { buffer = buf, nowait = true })

      notify.info("Summary generated (press 'q' to close)")
    end
  end)

  return true
end
