---@class Vibing.Core.ModesConstants
---モデル、権限モード、エージェントタイプの定数定義
local M = {}

local Agents = require("vibing.core.constants.agents")

---有効なモデル（claude短縮名。codex/copilot固有のモデル名は各command_builder側で自由入力を許可）
---@type string[]
M.VALID_MODELS = vim.tbl_map(function(m)
  return m.value
end, Agents.AGENTS[Agents.DEFAULT].models)

---権限モード
---@type string[]
M.PERMISSION_MODES = { "default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto" }

---有効なエージェント（バックエンド）
---@type string[]
M.VALID_AGENTS = Agents.ORDER

---エージェントモード（`agent.default_mode` / frontmatter の `mode`）
---ユーザーがそのチャットの意図を記録するためのメタデータで、現状は挙動を変えない。
---CLIにフラグとしては渡らない（権限モードの`plan`とは別物）。
---@type string[]
M.AGENT_MODES = { "code", "plan", "explore" }

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
  return Agents.is_valid(agent)
end

---エージェントモードが有効かチェック
---@param mode string
---@return boolean
function M.is_valid_agent_mode(mode)
  return vim.tbl_contains(M.AGENT_MODES, mode)
end

---agent modeとして使える値ならそのまま返し、そうでなければnilを返す
---呼び出し側は「nilが返った＋元がnilでない」で綴り間違いを検出できる
---@param mode any
---@return string|nil
function M.coerce_agent_mode(mode)
  if M.is_valid_agent_mode(mode) then
    return mode
  end
  return nil
end

return M
