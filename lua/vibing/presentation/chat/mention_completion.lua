local M = {}

---メンション補完関数
---@param findstart number 1の場合は補完開始位置を返す、0の場合は補完候補を返す
---@param base string 補完対象の文字列
---@return number|table 補完開始位置または補完候補リスト
function M.complete(findstart, base)
  if findstart == 1 then
    -- 補完開始位置を検索
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]

    -- カーソル位置から左に向かって @ を探す
    local start_col = col
    while start_col > 0 do
      local char = line:sub(start_col, start_col)
      if char == "@" then
        return start_col - 1 -- 0-indexed
      elseif char:match("%s") then
        -- 空白に到達したら@がないので補完しない
        return -1
      end
      start_col = start_col - 1
    end

    return -1
  else
    -- 補完候補を返す
    local dispatcher = require("vibing.application.shared_buffer.notification_dispatcher")
    local sessions = dispatcher.get_registered_sessions()

    local matches = {}

    -- @Claude- で始まる場合
    if base:match("^@Claude%-") then
      local pattern = base:sub(2) -- @ を除去
      for claude_id, _ in pairs(sessions) do
        if claude_id:find("^" .. vim.pesc(pattern)) then
          table.insert(matches, {
            word = claude_id,
            menu = "Mention",
            kind = "Session",
          })
        end
      end
    elseif base:match("^@") then
      -- @ のみの場合
      for claude_id, _ in pairs(sessions) do
        table.insert(matches, {
          word = claude_id,
          menu = "Mention",
          kind = "Session",
        })
      end

      -- @All も追加
      table.insert(matches, {
        word = "All",
        menu = "Broadcast",
        kind = "Special",
      })
    end

    return matches
  end
end

---チャットバッファに補完を設定
---@param buf number バッファ番号
function M.setup(buf)
  vim.api.nvim_buf_set_option(buf, "completefunc", "v:lua.require'vibing.presentation.chat.mention_completion'.complete")
end

return M
