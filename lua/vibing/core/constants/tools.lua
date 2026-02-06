---@class Vibing.Core.ToolsConstants
---Agent SDKで利用可能なツールの定数定義
local M = {}

---有効なツール名の配列
---@type string[]
M.VALID_TOOLS = {
  "Read",
  "Edit",
  "Write",
  "Bash",
  "Glob",
  "Grep",
  "WebSearch",
  "WebFetch",
  "Skill",
}

---有効なツール名のテーブル（高速検索用）
---@type table<string, boolean>
M.VALID_TOOLS_MAP = {}
for _, tool in ipairs(M.VALID_TOOLS) do
  M.VALID_TOOLS_MAP[tool] = true
end

---ツール名が有効かチェックし、正規化された名前を返す
---@param tool string チェックするツール名
---@return string|nil 有効な場合は正規化されたツール名
function M.validate_tool(tool)
  local tool_name, rule_content = tool:match("^([A-Za-z]+)%((.+)%)$")
  if tool_name and rule_content then
    -- Find matching valid tool name (case-insensitive)
    for _, valid in ipairs(M.VALID_TOOLS) do
      if tool_name:lower() == valid:lower() then
        return valid .. "(" .. rule_content .. ")"
      end
    end
    return nil
  end

  for _, valid in ipairs(M.VALID_TOOLS) do
    if tool:lower() == valid:lower() then
      return valid
    end
  end
  return nil
end

return M
