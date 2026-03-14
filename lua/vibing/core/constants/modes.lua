---@class Vibing.Core.ModesConstants
---Agent SDKのモデルと権限モードの定数定義
local M = {}

---有効なモデル
---@type string[]
M.VALID_MODELS = { "sonnet", "opus", "haiku" }

---権限モード (Agent SDK permissionMode)
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions" }

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

return M
