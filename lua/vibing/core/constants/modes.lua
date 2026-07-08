---@class Vibing.Core.ModesConstants
---モデル、権限モード、エージェントタイプの定数定義
local M = {}

---有効なモデル
---@type string[]
M.VALID_MODELS = { "sonnet", "opus", "haiku" }

---権限モード
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk" }

---有効なエージェント（バックエンド）
---@type string[]
M.VALID_AGENTS = { "claude", "codex" }

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
