---@class Vibing.Application.Mention.Handlers.CheckMentions
---/check-mentions スラッシュコマンドハンドラー
---未処理メンションを表示し、処理済みにマークする
local M = {}

local MentionUseCase = require("vibing.application.mention.use_case")

---スラッシュコマンドを実行
---@param chat_buffer table ChatBufferインスタンス
function M.execute(chat_buffer)
  local squad_name = vim.b[chat_buffer.buf].vibing_squad_name

  if not squad_name then
    vim.notify("No squad name assigned to this buffer", vim.log.levels.WARN)
    return
  end

  local mentions = MentionUseCase.get_unprocessed_mentions(squad_name)

  if #mentions == 0 then
    vim.notify("No unprocessed mentions for @" .. squad_name, vim.log.levels.INFO)
    return
  end

  -- 未処理メンションを表示
  local lines = {
    string.format("You have %d unprocessed mention(s):", #mentions),
    "",
  }

  for i, mention in ipairs(mentions) do
    table.insert(lines, string.format(
      "  [%d] %s from @%s:",
      i,
      mention.created_at,
      mention.from_squad_name
    ))
    -- コンテンツの最初の100文字を表示
    local preview = mention.content:sub(1, 100)
    if #mention.content > 100 then
      preview = preview .. "..."
    end
    table.insert(lines, "      " .. preview:gsub("\n", " "))
    table.insert(lines, "")
  end

  -- 全て処理済みにマーク
  MentionUseCase.mark_all_processed(squad_name)
  table.insert(lines, "All mentions marked as processed.")

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

return M
