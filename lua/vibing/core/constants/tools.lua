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
  -- CLIはv2.1.63でTaskをAgentに改名した。どちらのCLIが動いていても /allow が通るよう両方持つ
  "Task",
  "Agent",
}

---有効なツール名のテーブル（高速検索用）
---@type table<string, boolean>
M.VALID_TOOLS_MAP = {}
for _, tool in ipairs(M.VALID_TOOLS) do
  M.VALID_TOOLS_MAP[tool] = true
end

---permissions_allowの設定に関わらず、askやdenyに明示的に入っていなければ常に許可されるツール。
---
---収録の基準は「ファイルを作成・更新・削除しない読み取り専用のビルトインツール」であること。
---Edit/Write/Bashは当然対象外。Agent/Workflowはサブエージェント経由でファイルを変更しうるので外す。
---WebSearch/WebFetch/ShareOnboardingGuideはファイルこそ触らないが外部通信という別軸のリスクがあるので
---ここには入れない（DEFAULT_ALLOWED_TOOLSのコメントも参照）。
---
---ここはあくまで「既定では許可するがユーザーがask/denyで上書きできる」下限。ToolSearchやTodoWriteの
---ようなハーネス内部の制御ツールは、deny/askすら通さず常に許可すべきなのでcan_use_tool.luaの
---INTERNAL_TOOLS側に置く（あちらはこの下限より前で評価される）。
---@type string[]
M.ALWAYS_ALLOWED_TOOLS = {
  "Read",
  "Glob",
  "Grep",
  "Skill",
  "StructuredOutput",
}

---ALWAYS_ALLOWED_TOOLSの高速検索用マップ
---@type table<string, boolean>
M.ALWAYS_ALLOWED_TOOLS_MAP = {}
for _, tool in ipairs(M.ALWAYS_ALLOWED_TOOLS) do
  M.ALWAYS_ALLOWED_TOOLS_MAP[tool] = true
end

---Claude Codeハーネス内部の副作用なし制御ツール。`ask`/`deny`すら通さず常に許可される
---（can_use_tool.luaの評価順で`ALWAYS_ALLOWED_TOOLS`より前）。
---
---`ALWAYS_ALLOWED_TOOLS`との違いは「ユーザーがask/denyで上書きできるか」。あちらは上書き可・
---deny/denyルールより後ろで評価されるので、`Read`に対する`paths`限定のdenyルール（.env等）が効く。
---こちらは上書き不可・denyルールより前で許可を即決するので、止めるとハーネスが機能しなくなる
---制御ツールだけを収録する。「読み取り専用か」ではなく「ハーネスの制御に必須か」が基準なので、
---ファイルを変更するもの（NotebookEdit / EnterWorktree / Agent）も含む。`VALID_TOOLS`への登録は不要。
---@type string[]
M.INTERNAL_TOOLS = {
  "ToolSearch",
  "TodoWrite",
  "ReportFindings",
  "Agent",
  "Task",
  "TaskCreate",
  "TaskGet",
  "TaskList",
  "TaskOutput",
  "TaskStop",
  "TaskUpdate",
  "SendMessage",
  "Monitor",
  "ScheduleWakeup",
  "EnterPlanMode",
  "ExitPlanMode",
  "EnterWorktree",
  "ExitWorktree",
  "NotebookEdit",
}

---INTERNAL_TOOLSの高速検索用マップ
---@type table<string, boolean>
M.INTERNAL_TOOLS_MAP = {}
for _, tool in ipairs(M.INTERNAL_TOOLS) do
  M.INTERNAL_TOOLS_MAP[tool] = true
end

---vibing-nvim自身が提供するMCPツールの許可パターン。プレーンなユーザーレベルMCPサーバー登録
---（mcp__vibing-nvim__*）と、Claude Codeプラグイン登録（mcp__plugin_<marketplace>_vibing-nvim__*）の
---両方に対応する。
---
---プラグイン側の接頭辞は`mcp__plugin_vibing-nvim_vibing-nvim__`。マーケットプレイス名は
---.claude-plugin/marketplace.jsonの`name`（"vibing"）ではなく`claude plugin marketplace add`が
---実際に登録した名前で決まり、build.shが入れるのは`vibing-nvim@vibing-nvim`である（`claude plugin
---list --json`のidと、実際に配られるツール名の両方で確認済み）。
---
---ただしこのリストにマーケットプレイス名の追従を頼ってはいけない。--allowedToolsは具体的な
---プレフィックスしか受け付けず、ここがずれると当該ツールはCLI自身のゲートで止まる（#564）。
---最終的な担保はPreToolUseフックが返す明示的なallow決定のほうで、そちらは
---can_use_tool.M.is_vibing_nvim_mcp_toolのサフィックスマッチなのでマーケットプレイス名に依存しない。
---@type string[]
M.VIBING_NVIM_MCP_TOOL_PATTERNS = {
  "mcp__vibing-nvim__*",
  "mcp__plugin_vibing-nvim_vibing-nvim__*",
}

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
