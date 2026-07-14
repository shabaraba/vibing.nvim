---@class Vibing.Core.ModesConstants
---モデル、権限モード、エージェントタイプの定数定義
local M = {}

---Claude CLI のショートカットモデル名（sonnet/opus/...）
---codex/grok のモデル ID はここには含めない（各アダプター側で自由入力を許可）
---@type string[]
M.VALID_MODELS = { "sonnet", "opus", "haiku", "fable" }

---Grok Build CLI の既知モデル（/model 補完・デフォルト用。未掲載名も自由入力可）
---@type string[]
M.GROK_MODELS = { "grok-4.5", "grok-composer-2.5-fast" }

---権限モード
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto" }

---有効なエージェント（バックエンド）
---@type string[]
M.VALID_AGENTS = { "claude", "codex", "grok" }

---Claude ショートカットモデル名か
---@param model string
---@return boolean
function M.is_valid_model(model)
  return vim.tbl_contains(M.VALID_MODELS, model)
end

---エージェント種別に対して /model で設定可能なモデルか
---claude: VALID_MODELS のみ / codex・grok: 空でなければ自由入力
---@param model string
---@param agent string|nil "claude"|"codex"|"grok"
---@return boolean
function M.is_allowed_model_for_agent(model, agent)
  if type(model) ~= "string" or model == "" then
    return false
  end
  if agent == "codex" or agent == "grok" then
    return true
  end
  return M.is_valid_model(model)
end

---エージェント向けのデフォルト model を解決
---frontmatter 未指定時や、claude 用ショートカットが grok/codex に残っている場合に使う
---@param agent string|nil
---@param config_default string|nil config.agent.default_model
---@return string|nil
function M.default_model_for_agent(agent, config_default)
  if agent == "grok" then
    if config_default and not M.is_valid_model(config_default) then
      return config_default
    end
    return M.GROK_MODELS[1]
  end
  if agent == "codex" then
    if config_default and not M.is_valid_model(config_default) then
      return config_default
    end
    return nil
  end
  return config_default or "sonnet"
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
