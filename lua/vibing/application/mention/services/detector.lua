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

  -- Assistantセクション内の行頭メンションを抽出し、次のヘッダーまでの全文を取得
  for i = last_assistant_start, last_assistant_end do
    local line = lines[i]

    -- 行頭の @SquadName パターンのみを検出
    local squad_name = line:match("^@(%w+)")
    if squad_name then
      -- メンション行から次のヘッダーまでの全文を収集
      local content_lines = {}
      for j = i, last_assistant_end do
        -- 次のヘッダー（## で始まる行）に到達したら終了
        if j > i and lines[j]:match("^##%s") then
          break
        end
        table.insert(content_lines, lines[j])
      end

      -- @SquadName の後ろの部分から開始
      local first_line = content_lines[1]
      local mention_content = first_line:match("^@%w+%s+(.*)") or ""

      -- 残りの行を追加
      for k = 2, #content_lines do
        if content_lines[k] ~= "" or k < #content_lines then
          mention_content = mention_content .. "\n" .. content_lines[k]
        end
      end

      -- 末尾の空行を削除
      mention_content = mention_content:gsub("\n+$", "")

      table.insert(mentions, {
        squad_name = squad_name,
        content = mention_content,
      })
    end
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
