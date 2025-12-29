---@class Vibing.Domain.PermissionRule
---権限ルールエンティティ
---ツール使用の許可/拒否ルールを表現
local PermissionRule = {}
PermissionRule.__index = PermissionRule

---新しいルールを作成
---@param tools string[] 対象ツール
---@param action "allow"|"deny" アクション
---@return Vibing.Domain.PermissionRule
function PermissionRule:new(tools, action)
  local instance = setmetatable({}, self)
  instance.tools = tools or {}
  instance.action = action or "allow"
  instance.paths = nil
  instance.commands = nil
  instance.patterns = nil
  instance.domains = nil
  instance.message = nil
  return instance
end

---パスパターンを設定
---@param paths string[]
---@return Vibing.Domain.PermissionRule
function PermissionRule:with_paths(paths)
  self.paths = paths
  return self
end

---コマンドを設定
---@param commands string[]
---@return Vibing.Domain.PermissionRule
function PermissionRule:with_commands(commands)
  self.commands = commands
  return self
end

---パターンを設定
---@param patterns string[]
---@return Vibing.Domain.PermissionRule
function PermissionRule:with_patterns(patterns)
  self.patterns = patterns
  return self
end

---ドメインを設定
---@param domains string[]
---@return Vibing.Domain.PermissionRule
function PermissionRule:with_domains(domains)
  self.domains = domains
  return self
end

---メッセージを設定
---@param message string
---@return Vibing.Domain.PermissionRule
function PermissionRule:with_message(message)
  self.message = message
  return self
end

---ルールが特定のツールに適用されるかチェック
---@param tool string
---@return boolean
function PermissionRule:applies_to_tool(tool)
  return vim.tbl_contains(self.tools, tool)
end

---ルールが許可ルールかチェック
---@return boolean
function PermissionRule:is_allow()
  return self.action == "allow"
end

---ルールが拒否ルールかチェック
---@return boolean
function PermissionRule:is_deny()
  return self.action == "deny"
end

---辞書からルールを作成
---@param dict table
---@return Vibing.Domain.PermissionRule
function PermissionRule.from_dict(dict)
  local rule = PermissionRule:new(dict.tools, dict.action)
  rule.paths = dict.paths
  rule.commands = dict.commands
  rule.patterns = dict.patterns
  rule.domains = dict.domains
  rule.message = dict.message
  return rule
end

return PermissionRule
