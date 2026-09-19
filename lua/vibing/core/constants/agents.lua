---@class Vibing.Core.AgentsConstants
---バックエンド（エージェント）定義の単一ソース。派生先と経緯は architecture.md を参照。
---
---このモジュールは意図的に何も require しない。派生先がここを require する一方向の依存に
---しておくことで、循環 require が構造的に起きないようにしている。
local M = {}

---@class Vibing.AgentModelCandidate
---@field value string モデル識別子
---@field description string 補完UIに出す説明

---@class Vibing.AgentConfigField
---`setup().backends.<id>.<field>` の1項目。`config.lua` が既定値の組み立てと検証をここから導く
---ので、バックエンド固有の設定キーが共有コードに名前で現れない（ADR 009）
---@field kind "string"|"boolean"|"path_or_false"|"executable_or_auto" 検証の種類
---@field values string[]? `kind = "string"` のとき、許される値の全体。設定されていれば
---  `config.lua` が enum として検証し、範囲外は警告して既定値に戻す
---@field default any 既定値。`default_module` があればそちらが優先
---@field default_module string? 既定値を持つモジュールの require パス（このファイルは何も
---  require しないので、文字列の既定値を別モジュールから借りるときはこう書く）
---@field default_field string? `default_module` 内のフィールド名
---@field legacy string[]? ADR 009 以前にこの項目があった `setup()` 上の位置。設定されていれば
---  警告付きで `backends.<id>.<field>` へ移す

---@class Vibing.AgentDefinition
---@field id string エージェント識別子（frontmatter の `agent` フィールドの値）
---@field adapter_module string アダプターの require パス（`cli_adapter.define` を通す互換シム）
---@field descriptor_module string バックエンド記述子（`Vibing.BackendDescriptor`）の require パス。
---  アダプターの実体は `infrastructure/adapter/cli_adapter.lua` 一つで、バックエンドごとの差は
---  この記述子が持つ（ADR 009）
---@field command_builder_module string argv を組み立てるモジュールの require パス。テストが
---  バックエンドを一覧するときに使う（列挙を手で並べると新しいバックエンドで更新漏れが起きる）
---@field export_name string `infrastructure/init.lua` でのエクスポート名
---@field description string frontmatter 補完の agent enum に出す説明
---@field models Vibing.AgentModelCandidate[] 補完候補。妥当性検証ではない（自由入力を許す
---  バックエンドもある）ので、ここに無いモデルを弾く用途には使わないこと
---@field config_fields table<string, Vibing.AgentConfigField>? `setup().backends.<id>` の項目

---@type table<string, Vibing.AgentDefinition>
M.AGENTS = {
  claude = {
    id = "claude",
    adapter_module = "vibing.infrastructure.adapter.claude_cli",
    descriptor_module = "vibing.infrastructure.adapter.backends.claude",
    command_builder_module = "vibing.infrastructure.adapter.modules.cli_command_builder",
    export_name = "ClaudeCLIAdapter",
    description = "Claude CLI (Anthropic)",
    config_fields = {
      -- 1ターン1プロセス（`oneshot`）か、チャットに常駐する1プロセスが複数ターンを捌くか
      -- （`duplex`、#777）。値の定義は `adapter/modules/process_model.lua`（このファイルは
      -- 何も require しないので文字列を直接書く）。チャット単位の上書きは frontmatter の
      -- `process:`。既定が `oneshot` なのは、常駐プロセスがアイドル時も約200MBを占めるため
      process = {
        kind = "string",
        values = { "oneshot", "duplex" },
        default = "oneshot",
      },
    },
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
    descriptor_module = "vibing.infrastructure.adapter.backends.codex",
    command_builder_module = "vibing.infrastructure.adapter.modules.codex_command_builder",
    export_name = "CodexCLIAdapter",
    description = "Codex CLI (OpenAI)",
    config_fields = {
      -- Project-local OS sandbox profile; `false` disables loading it.
      profile_file = {
        kind = "path_or_false",
        default = ".vibing/codex-permissions.toml",
        legacy = { "permissions", "codex_profile_file" },
      },
      -- Initial TOML, consulted only when the profile file is first created.
      profile_content = {
        kind = "string",
        default_module = "vibing.core.utils.project_codex_permissions",
        default_field = "DEFAULT_CONTENT",
        legacy = { "permissions", "codex_profile_content" },
      },
      -- A Git-tracked profile is refused until the user says they reviewed it.
      allow_tracked_profile = {
        kind = "boolean",
        default = false,
        legacy = { "permissions", "codex_allow_tracked_profile" },
      },
      -- codex の軽量呼び出しは --ignore-user-config で走るので、ユーザーの model_provider が落ちて
      -- 既定の OpenAI エンドポイントに向く。それを 1 セッション 1 回だけ警告する。
      --
      -- auto_resume_on_limit や dap と違って既定で有効なのは、これがトークンを使う機能ではなく、
      -- 黙って宛先が変わることを防ぐ通知だから。既定で無効なら、気づけないという当の問題が残る。
      -- 代償は `codex doctor --json` の起動が 1 回入ることで、doctor には単一チェックだけ走らせる
      -- フラグが無いためプロバイダへの到達性通信も付いてくる。それを避けたい場合は false にする。
      provider_notice = {
        kind = "boolean",
        default = true,
        legacy = { "agent", "codex_provider_notice", "enabled" },
      },
    },
    models = {
      { value = "gpt-6-astra", description = "GPT-6 Astra (strongest Codex work)" },
      { value = "gpt-5.6-sol", description = "GPT-5.6 Sol (deep reasoning)" },
      { value = "gpt-5.6-terra", description = "GPT-5.6 Terra (everyday Codex work)" },
      { value = "gpt-5.6-luna", description = "GPT-5.6 Luna (fast, narrow tasks)" },
      { value = "gpt-5.5", description = "GPT-5.5 (previous generation)" },
      { value = "gpt-5-codex", description = "GPT-5 Codex (API-key auth / Responses API)" },
      { value = "gpt-5.3-codex-spark", description = "GPT-5.3 Codex Spark (preview, when available)" },
    },
  },
  copilot = {
    id = "copilot",
    adapter_module = "vibing.infrastructure.adapter.copilot_cli",
    descriptor_module = "vibing.infrastructure.adapter.backends.copilot",
    command_builder_module = "vibing.infrastructure.adapter.modules.copilot_command_builder",
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
  grok = {
    id = "grok",
    adapter_module = "vibing.infrastructure.adapter.grok_cli",
    descriptor_module = "vibing.infrastructure.adapter.backends.grok",
    command_builder_module = "vibing.infrastructure.adapter.modules.grok_command_builder",
    export_name = "GrokCLIAdapter",
    description = "Grok Build CLI (xAI)",
    config_fields = {
      -- "auto" looks `grok` up on PATH; a path is used as given and never silently reset.
      executable = {
        kind = "executable_or_auto",
        default = "auto",
        legacy = { "grok", "executable" },
      },
    },
    models = {
      { value = "grok-4.5", description = "Grok 4.5" },
      { value = "grok-composer-2.5-fast", description = "Grok Composer 2.5 Fast" },
    },
  },
}

---列挙順。`pairs()` の順序は不定なので、ユーザーに見える一覧はすべてこれを経由する。
---@type string[]
M.ORDER = { "claude", "codex", "copilot", "grok" }

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

---@param id string?
---@return Vibing.AgentModelCandidate[]
function M.models_for(id)
  return M.get(id).models
end

---@param id string
---@return table<string, Vibing.AgentConfigField>
function M.config_fields(id)
  return (M.AGENTS[id] and M.AGENTS[id].config_fields) or {}
end

---@return string[] all known model candidate values, keeping backend order and removing duplicates
function M.all_model_values()
  local values = {}
  local seen = {}
  for _, def in ipairs(M.list()) do
    for _, model in ipairs(def.models) do
      if not seen[model.value] then
        seen[model.value] = true
        table.insert(values, model.value)
      end
    end
  end
  return values
end

return M
