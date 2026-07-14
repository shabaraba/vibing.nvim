---@class Vibing.Core.ModesConstants
---モデル、権限モード、エージェントタイプの定数定義
local M = {}

---有効なモデル（claude/codex共通で許可される名称。codex固有のモデル名はcodex_command_builder側で自由入力を許可）
---@type string[]
M.VALID_MODELS = { "sonnet", "opus", "haiku", "fable" }

---権限モード
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto" }

---有効なエージェント（バックエンド）
---@type string[]
M.VALID_AGENTS = { "claude", "codex", "grok" }

---モデルが有効かチェック
---@param model string
---@return boolean
function M.is_valid_model(model)
  return vim.tbl_contains(M.VALID_MODELS, model)
end

---権限モードが有効かチェック
---@param mode string
---@return boolean
function M.is_valid_permission_mode(mode)
  return vim.tbl_contains(M.PERMISSION_MODES, mode)
end

---エージェントが有効かチェック
---@param agent string
---@return boolean
function M.is_valid_agent(agent)
  return vim.tbl_contains(M.VALID_AGENTS, agent)
end

return M
