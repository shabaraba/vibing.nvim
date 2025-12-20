---@class Vibing.Completion
---スラッシュコマンドの補完機能
local M = {}

---スラッシュコマンドの補完を提供するomnifunc
---Neovimの組み込み補完システム（Ctrl+X Ctrl+O）で使用
---@param findstart number 0: 補完開始位置を返す、1: 補完候補を返す
---@param base string 補完対象の文字列（findstart=1の時のみ）
---@return number|table findstart=0: 補完開始列番号、findstart=1: 補完候補のリスト
function M.slash_command_complete(findstart, base)
  if findstart == 1 then
    -- 補完開始位置を返す
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]

    -- カーソル位置から左に/を探す
    local before_cursor = line:sub(1, col)
    local slash_pos = before_cursor:match("^.*/()")

    if slash_pos then
      return slash_pos - 1  -- 0-indexed
    else
      return -1  -- 補完しない
    end
  else
    -- 補完候補を返す
    local commands = require("vibing.chat.commands")
    local all_commands = commands.list_all()

    local candidates = {}
    for name, cmd in pairs(all_commands) do
      -- base で始まるコマンドのみをフィルタ
      if name:find("^" .. vim.pesc(base), 1, false) then
        table.insert(candidates, {
          word = name,
          abbr = "/" .. name,
          kind = cmd.source == "builtin" and "B" or "C",  -- B=Builtin, C=Custom
          menu = cmd.description or "",
        })
      end
    end

    -- 名前順にソート
    table.sort(candidates, function(a, b)
      return a.word < b.word
    end)

    return candidates
  end
end

return M
