---@class Vibing.Presentation.SubagentFinder
---チャットバッファに記録された `<!-- subagent: ... -->` マーカーを拾う
local M = {}

local SUBAGENT_COMMENT_PATTERN = "<!%-%- subagent: ([%w_%-]+) type=([^%s]*) %-%->"

---@class Vibing.SubagentRef
---@field agent_id string
---@field subagent_type string
---@field line number 1-based

---@param buf number
---@return Vibing.SubagentRef[] 出現順。同じagent_idは最初の1件だけ返す
function M.find_all(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return {}
  end

  local found = {}
  local seen = {}
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local agent_id, subagent_type = line:match(SUBAGENT_COMMENT_PATTERN)
    -- 同じsubagentを何度も呼ぶとマーカーも複数残るので、選択肢としては1件に畳む
    if agent_id and not seen[agent_id] then
      seen[agent_id] = true
      table.insert(found, { agent_id = agent_id, subagent_type = subagent_type, line = i })
    end
  end

  return found
end

---@param ref Vibing.SubagentRef
---@return string ピッカー表示用のラベル
function M.describe(ref)
  local label = (ref.subagent_type ~= "" and ref.subagent_type) or "subagent"
  return string.format("%s (%s)", label, ref.agent_id:sub(1, 8))
end

return M
