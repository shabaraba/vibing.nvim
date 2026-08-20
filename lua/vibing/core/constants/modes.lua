---@class Vibing.Core.ModesConstants
---モデル、権限モード、エージェントタイプの定数定義
local M = {}

local Agents = require("vibing.core.constants.agents")

---有効なモデル（claude短縮名。codex/copilot固有のモデル名は各command_builder側で自由入力を許可）
---@type string[]
M.VALID_MODELS = vim.tbl_map(function(m)
  return m.value
end, Agents.get(Agents.DEFAULT).models)

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

---推論量のレベル。claude CLI の `--effort` がそのまま受け取る値。
---CLI は未知の値を弾かず黙って無視するので、渡す前にここで検証する。
--- string[]
M.EFFORT_LEVELS = { "low", "medium", "high", "xhigh", "max" }

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
---effortレベルが有効かチェック
--- effort string
--- boolean
function M.is_valid_effort(effort)
  return vim.tbl_contains(M.EFFORT_LEVELS, effort)
end

function M.is_valid_agent_mode(mode)
  return vim.tbl_contains(M.AGENT_MODES, mode)
end

---チャットが実際に話す相手のバックエンドを解決する
---frontmatterの`agent` > `config.adapter` > 既定（claude）。未知の名前は
---`send_message._resolve_adapter`と同じくフォールバックする（警告はそちらが1度だけ出す）。
---バックエンド単位のスコープを持つもの（使用量リミットの記録など）は、実際に使われる
---アダプターとここで一致していないと、使われないバックエンドに対して働いてしまう。
---@param frontmatter table|nil
---@param config table|nil
---@return string
function M.resolve_agent(frontmatter, config)
  local from_frontmatter = frontmatter and frontmatter.agent
  if M.is_valid_agent(from_frontmatter) then
    return from_frontmatter
  end

  local from_config = config and config.adapter
  if M.is_valid_agent(from_config) then
    return from_config
  end

  return Agents.DEFAULT
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
