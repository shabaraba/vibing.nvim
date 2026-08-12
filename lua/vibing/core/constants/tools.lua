---@class Vibing.Core.ToolsConstants
---Claude CLIで利用可能なツールの定数定義
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
  "StructuredOutput",
}

---有効なツール名のテーブル（高速検索用）
---@type table<string, boolean>
M.VALID_TOOLS_MAP = {}
for _, tool in ipairs(M.VALID_TOOLS) do
  M.VALID_TOOLS_MAP[tool] = true
end

---permissions_allowの設定に関わらず、askやdenyに明示的に入っていなければ常に許可されるツール
---@type string[]
M.ALWAYS_ALLOWED_TOOLS = {
  "Read",
  "Skill",
  "StructuredOutput",
}

---ALWAYS_ALLOWED_TOOLSの高速検索用マップ
---@type table<string, boolean>
M.ALWAYS_ALLOWED_TOOLS_MAP = {}
for _, tool in ipairs(M.ALWAYS_ALLOWED_TOOLS) do
  M.ALWAYS_ALLOWED_TOOLS_MAP[tool] = true
end

---`permissions.allow`の既定値。`config.lua`はこのリストを参照するだけで、値を再列挙しない。
---VALID_TOOLSからの差集合としては導出しない。導出にするとVALID_TOOLSへツールを足した人が
---「既定で許可してよいか」を判断しないまま自動的に許可され得るため、あえて列挙にしてその判断を
---1行の追加として残す。ここに無いのはBash（任意コマンド実行）とWebSearch/WebFetch（外部通信）。
---`ALWAYS_ALLOWED_TOOLS`とは別物で、あちらは`allow`の内容に関わらず効く下限。ここから外しても
---あちらに残っていれば許可されたままになる。
---@type string[]
M.DEFAULT_ALLOWED_TOOLS = {
  "Read",
  "Edit",
  "Write",
  "Glob",
  "Grep",
  "Skill",
  "StructuredOutput",
}

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
