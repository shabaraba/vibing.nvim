---@class Vibing.Application.Mention.Detector
---メンション検知サービス
---バッファ内の @SquadName パターンを検出
local M = {}

---最後のAssistantセクションから @SquadName メンションを抽出
---@param bufnr number バッファ番号
---@return table[] mentions { squad_name: string, content: string }[]
function M.detect_mentions_in_last_response(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local mentions = {}

  -- 最後のAssistantセクションを探す
  local last_assistant_start = nil
  for i = #lines, 1, -1 do
    if lines[i]:match("^## Assistant") then
      last_assistant_start = i
      break
    end
  end

  if not last_assistant_start then
    return {}
  end

  -- 次のUserセクションまたはバッファ末尾までを取得
  local last_assistant_end = #lines
  for i = last_assistant_start + 1, #lines do
    if lines[i]:match("^## User") then
      last_assistant_end = i - 1
      break
    end
  end

  -- Assistantセクション内の全メンションを抽出
  local content_lines = {}
  for i = last_assistant_start, last_assistant_end do
    table.insert(content_lines, lines[i])
  end
  local content = table.concat(content_lines, "\n")

  -- @SquadName パターンを検出
  for squad_name in content:gmatch("@(%w+)") do
    -- メンション内容を抽出（簡易版: 同じ行の内容）
    table.insert(mentions, {
      squad_name = squad_name,
      content = content,
    })
  end

  return mentions
end

---Squad名が有効かチェック
---@param squad_name string
---@return boolean
function M.is_valid_squad_name(squad_name)
  local valid_names = {
    "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot",
    "Golf", "Hotel", "India", "Juliet", "Kilo", "Lima",
    "Mike", "November", "Oscar", "Papa", "Quebec", "Romeo",
    "Sierra", "Tango", "Uniform", "Victor", "Whiskey",
    "Xray", "Yankee", "Zulu", "Commander"
  }

  for _, name in ipairs(valid_names) do
    if name == squad_name then
      return true
    end
  end

  return false
end

return M
