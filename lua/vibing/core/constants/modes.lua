---@class Vibing.Core.ModesConstants
---Agent SDKのモードとモデルの定数定義
local M = {}

---有効なモード
---@type string[]
M.VALID_MODES = { "code", "plan", "explore" }

---有効なモデル
---@type string[]
M.VALID_MODELS = { "sonnet", "opus", "haiku" }

---権限モード
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions" }

---モードが有効かチェック
---@param mode string
---@return boolean
function M.is_valid_mode(mode)
  return vim.tbl_contains(M.VALID_MODES, mode)
end

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
