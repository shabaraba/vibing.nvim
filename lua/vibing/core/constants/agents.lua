---@class Vibing.Core.AgentsConstants
---バックエンド（エージェント）定義の単一ソース。
---`factory.lua` / `modes.lua` / `completion/providers/frontmatter.lua` / `infrastructure/init.lua`
---はすべてここから派生する。以前はこの4箇所に同じ知識が散っていて、`VALID_AGENTS` にあって
---factory に無いエージェントが検証を通った上で黙って claude にフォールバックし得た。
---バックエンドの追加はこのファイル1箇所の変更で完結する。
---
---このモジュールは意図的に何も require しない。派生先がここを require する一方向の依存に
---しておくことで、循環 require が構造的に起きないようにしている。
local M = {}

---@class Vibing.AgentModelCandidate
---@field value string モデル識別子
---@field description string 補完UIに出す説明

---@class Vibing.AgentDefinition
---@field id string エージェント識別子（frontmatter の `agent` フィールドの値）
---@field adapter_module string アダプターの require パス
---@field export_name string `infrastructure/init.lua` でのエクスポート名
---@field description string frontmatter 補完の agent enum に出す説明
---@field models Vibing.AgentModelCandidate[] 補完候補。妥当性検証ではない（自由入力を許す
---  バックエンドもある）ので、ここに無いモデルを弾く用途には使わないこと

---@type table<string, Vibing.AgentDefinition>
M.AGENTS = {
  claude = {
    id = "claude",
    adapter_module = "vibing.infrastructure.adapter.claude_cli",
    export_name = "ClaudeCLIAdapter",
    description = "Claude CLI (Anthropic)",
    models = {
      { value = "haiku", description = "Claude Haiku (fastest)" },
      { value = "sonnet", description = "Claude Sonnet (balanced)" },
      { value = "opus", description = "Claude Opus (most capable)" },
      { value = "fable", description = "Claude Fable" },
    },
  },
  codex = {
    id = "codex",
    adapter_module = "vibing.infrastructure.adapter.codex_cli",
    export_name = "CodexCLIAdapter",
    description = "Codex CLI (OpenAI)",
    models = {
      { value = "gpt-5.5", description = "GPT-5.5 (default)" },
      { value = "gpt-5.4", description = "gpt-5.4" },
      { value = "gpt-5.4-mini", description = "GPT-5.4-Mini" },
      { value = "gpt-5.3-codex", description = "gpt-5.3-codex" },
      { value = "gpt-5.2", description = "gpt-5.2" },
    },
  },
  copilot = {
    id = "copilot",
    adapter_module = "vibing.infrastructure.adapter.copilot_cli",
    export_name = "CopilotCLIAdapter",
    description = "GitHub Copilot CLI",
    -- copilot は30種類以上のモデルを持つため、代表的なものだけを候補に出す。
    -- 実際に使えるモデルは利用者のプランに依存するので、ここは候補提示であって検証ではない。
    models = {
      { value = "auto", description = "Let Copilot pick the model" },
      { value = "claude-sonnet-5", description = "Claude Sonnet 5" },
      { value = "claude-opus-5", description = "Claude Opus 5" },
      { value = "claude-haiku-4.5", description = "Claude Haiku 4.5 (fastest)" },
      { value = "gpt-5.5", description = "GPT-5.5" },
      { value = "gpt-5.4", description = "GPT-5.4" },
      { value = "gpt-5.4-mini", description = "GPT-5.4 Mini" },
      { value = "gpt-5.3-codex", description = "GPT-5.3 Codex" },
      { value = "gemini-3.1-pro-preview", description = "Gemini 3.1 Pro (preview)" },
    },
  },
}

---列挙順。`pairs()` の順序は不定なので、ユーザーに見える一覧はすべてこれを経由する。
---@type string[]
M.ORDER = { "claude", "codex", "copilot" }

---未知・未指定のエージェントのフォールバック先
---@type string
M.DEFAULT = "claude"

---@return Vibing.AgentDefinition[] ORDER順の定義配列
function M.list()
  local out = {}
  for _, id in ipairs(M.ORDER) do
    table.insert(out, M.AGENTS[id])
  end
  return out
end

---@param id string?
---@return boolean
function M.is_valid(id)
  return id ~= nil and M.AGENTS[id] ~= nil
end

---@param id string?
---@return Vibing.AgentDefinition 未知のidならDEFAULTの定義
function M.get(id)
  return M.AGENTS[id] or M.AGENTS[M.DEFAULT]
end

return M
