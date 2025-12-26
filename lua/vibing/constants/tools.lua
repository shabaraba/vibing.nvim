---@class Vibing.ToolsConstants
---Agent SDKで利用可能なツールの定数定義
---複数のモジュールで共有される有効なツール名リスト
local M = {}

---有効なツール名の配列
---@type string[]
M.VALID_TOOLS = { "Read", "Edit", "Write", "Bash", "Glob", "Grep", "WebSearch", "WebFetch" }

---有効なツール名のテーブル（高速検索用）
---@type table<string, boolean>
M.VALID_TOOLS_MAP = {}
for _, tool in ipairs(M.VALID_TOOLS) do
  M.VALID_TOOLS_MAP[tool] = true
end

---ツール名が有効かチェックし、正規化された名前を返す
---大文字小文字を区別せずにマッチし、正しい形式の名前を返す
---Granular構文（Tool(pattern)）を全ツールでサポート
---@param tool string チェックするツール名
---@return string|nil 有効な場合は正規化されたツール名、無効な場合はnil
function M.validate_tool(tool)
  -- Check for granular pattern syntax: Tool(ruleContent)
  local tool_name, rule_content = tool:match("^([A-Za-z]+)%((.+)%)$")
  if tool_name and rule_content then
    -- Normalize tool name (capitalize first letter)
    local normalized = tool_name:sub(1, 1):upper() .. tool_name:sub(2):lower()

    -- Verify it's a valid tool name
    if M.VALID_TOOLS_MAP[normalized] then
      -- Valid granular syntax for known tool
      return normalized .. "(" .. rule_content .. ")"
    end
    -- Unknown tool with pattern - reject
    return nil
  end

  -- Check basic tool names (no pattern)
  for _, valid in ipairs(M.VALID_TOOLS) do
    if tool:lower() == valid:lower() then
      return valid
    end
  end
  return nil
end

return M
