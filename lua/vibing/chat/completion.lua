---Slash command completion
local M = {}

---Omnifunc for slash command completion
---@param findstart number
---@param base string
---@return number|table
function M.omnifunc(findstart, base)
  if findstart == 1 then
    -- カーソル位置から行頭までのテキストを取得
    local line = vim.api.nvim_get_current_line()
    local col = vim.fn.col(".")
    local line_to_cursor = line:sub(1, col - 1)

    -- 最後の/を探す
    local slash_pos = line_to_cursor:match("^.*()/%S*$")
    if slash_pos then
      return slash_pos - 1 -- 0-indexed position
    end

    return -3 -- 補完を開始しない
  else
    -- 補完候補を生成
    local commands = require("vibing.chat.commands")
    local candidates = {}

    for _, cmd in ipairs(commands.list()) do
      local word = "/" .. cmd.name
      -- baseで始まるコマンドのみを候補に含める
      if base == "" or word:sub(1, #base) == base then
        table.insert(candidates, {
          word = word,
          abbr = word,
          menu = cmd.description,
          dup = 0,
        })
      end
    end

    return candidates
  end
end

return M
