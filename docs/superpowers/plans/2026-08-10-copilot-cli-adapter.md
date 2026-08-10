# GitHub Copilot CLI アダプター Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** vibing.nvim のバックエンドとして GitHub Copilot CLI (`copilot`) を 3 つ目の選択肢として
追加し、`adapter = "copilot"` とフロントマターの `agent: copilot` で選べるようにする。

**Architecture:** 既存の `codex_cli` アダプターと同型の構成を取る。`Base` アダプターを継承した
`copilot_cli.lua` が `copilot -p --output-format json` を `vim.system()` で起動し、JSONL の
イベントストリームを `copilot_event_processor.lua` が chunk / ツール表示 / セッション ID に変換する。
`stream_handler` / `session_manager` / `active_stream_registry` は既存モジュールを再利用する。

**Tech Stack:** Lua (Neovim 0.10+ の `vim.system`), plenary.nvim (busted 形式のテスト),
GitHub Copilot CLI 1.0.78+

**設計ドキュメント:** `docs/superpowers/specs/2026-08-10-copilot-cli-adapter-design.md`

## Global Constraints

- **npm は使用禁止**。すべて `pnpm` を使う。`pnpm test` は内部で `npm run test:lua` を呼ぶので
  使えない。テストは必ず `pnpm run test:lua` を直接叩く。
- **1 ファイル 100 行程度**（最大 200 行）。超えそうなら責務で分割する。
- **不要なコメントを残さない**。既存ファイルのコメント密度（LuaLS の `---@` アノテーション中心）に
  合わせる。
- **モック・スタブは実装コードで使用禁止**。テストコード内でのみ許可。
- **コミットは各タスクの最終ステップでのみ行う**。メッセージは英語の Semantic Commit Messages。
  `🤖 Generated with Claude Code` や `Co-Authored-By:` などのフッターは **付けない**。
- **命名に段階的リファクタを示す接頭辞・接尾辞を使わない**（`New*`, `*V2`, `*Optimized` など）。
- 新規ツールを権限バリデーションに追加する必要はない（本作業では新しいツール名を導入しない）。
- copilot CLI の最小バージョンは **1.0.78**。`--output-format json` / `--stream` /
  `--resume=<id>` / `--deny-tool` はこのバージョンで実機検証済み。

## 実装順序と依存関係

```text
Task 1 (command_builder)  ─┐
Task 2 (item_display)     ─┼─> Task 4 (copilot_cli) ─> Task 5 (factory + 登録) ─> Task 7 (docs)
Task 3 (event_processor) ──┘                            Task 6 (補完)
```

Task 3 は Task 2 に依存する。Task 4 は Task 1〜3 すべてに依存する。Task 6 は独立して実施可能。

---

### Task 1: コマンドビルダー

`copilot` を起動するためのコマンド配列を組み立てる純粋なモジュール。権限モードのマッピングと
deny リストの変換ロジックがここに集約される。

**Files:**

- Create: `lua/vibing/infrastructure/adapter/modules/copilot_command_builder.lua`
- Test: `tests/copilot_command_builder_spec.lua`

**Interfaces:**

- Consumes: `vibing.core.constants.modes` の `Modes.is_valid_model(model)`,
  `vibing.core.utils.language` の `language_names` テーブル
- Produces:
  - `M.build(prompt, opts, session_id, config) -> string[]`
  - `M.to_deny_pattern(entry) -> string|nil`
  - `M.build_deny_patterns(deny) -> string[]`
  - `M._set_executable_path(path)` — テスト専用の実行ファイルパス注入シーム

- [ ] **Step 1: 失敗するテストを書く**

`tests/copilot_command_builder_spec.lua` を新規作成する。

```lua
local Builder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")

---コマンド配列に指定の値が含まれるか
---@param cmd string[]
---@param value string
---@return boolean
local function contains(cmd, value)
  for _, v in ipairs(cmd) do
    if v == value then
      return true
    end
  end
  return false
end

---コマンド配列内で flag の直後に来る値を返す
---@param cmd string[]
---@param flag string
---@return string|nil
local function value_after(cmd, flag)
  for i, v in ipairs(cmd) do
    if v == flag then
      return cmd[i + 1]
    end
  end
  return nil
end

describe("copilot_command_builder", function()
  before_each(function()
    Builder._set_executable_path("/usr/local/bin/copilot")
  end)

  after_each(function()
    Builder._set_executable_path(nil)
  end)

  describe("to_deny_pattern", function()
    it("maps Bash to shell()", function()
      assert.are.equal("shell()", Builder.to_deny_pattern("Bash"))
    end)

    it("maps Bash(npm:*) to shell(npm:*)", function()
      assert.are.equal("shell(npm:*)", Builder.to_deny_pattern("Bash(npm:*)"))
    end)

    it("maps Write and Edit to write()", function()
      assert.are.equal("write()", Builder.to_deny_pattern("Write"))
      assert.are.equal("write()", Builder.to_deny_pattern("Edit"))
    end)

    it("maps WebFetch and WebSearch to url()", function()
      assert.are.equal("url()", Builder.to_deny_pattern("WebFetch"))
      assert.are.equal("url()", Builder.to_deny_pattern("WebSearch"))
    end)

    it("returns nil for unmapped tools", function()
      assert.is_nil(Builder.to_deny_pattern("Read"))
      assert.is_nil(Builder.to_deny_pattern("Glob"))
    end)
  end)

  describe("build_deny_patterns", function()
    it("deduplicates write() from Write and Edit", function()
      local patterns = Builder.build_deny_patterns({ "Write", "Edit", "Bash" })
      assert.are.same({ "write()", "shell()" }, patterns)
    end)

    it("returns an empty list for nil", function()
      assert.are.same({}, Builder.build_deny_patterns(nil))
    end)
  end)

  describe("build", function()
    it("emits the base flags with the prompt last", function()
      local cmd = Builder.build("hello", {}, nil, {})
      assert.are.equal("/usr/local/bin/copilot", cmd[1])
      assert.is_true(contains(cmd, "--output-format"))
      assert.are.equal("json", value_after(cmd, "--output-format"))
      assert.are.equal("on", value_after(cmd, "--stream"))
      assert.is_true(contains(cmd, "--no-color"))
      assert.are.equal("-p", cmd[#cmd - 1])
      assert.are.equal("hello", cmd[#cmd])
    end)

    it("adds --resume when a session id is given", function()
      local cmd = Builder.build("hi", {}, "sess-123", {})
      assert.is_true(contains(cmd, "--resume=sess-123"))
    end)

    it("omits --resume for a new session", function()
      local cmd = Builder.build("hi", {}, nil, {})
      assert.is_nil(value_after(cmd, "--resume"))
      for _, v in ipairs(cmd) do
        assert.is_nil(v:match("^%-%-resume="))
      end
    end)

    it("passes through copilot model ids", function()
      local cmd = Builder.build("hi", { model = "gpt-5.5" }, nil, {})
      assert.are.equal("gpt-5.5", value_after(cmd, "--model"))
    end)

    it("drops claude short model names", function()
      local cmd = Builder.build("hi", { model = "sonnet" }, nil, {})
      assert.is_nil(value_after(cmd, "--model"))
    end)

    it("falls back to config.agent.default_model", function()
      local cmd = Builder.build("hi", {}, nil, { agent = { default_model = "claude-opus-5" } })
      assert.are.equal("claude-opus-5", value_after(cmd, "--model"))
    end)

    it("maps bypassPermissions to --allow-all", function()
      local cmd = Builder.build("hi", { permission_mode = "bypassPermissions" }, nil, {})
      assert.is_true(contains(cmd, "--allow-all"))
      assert.is_false(contains(cmd, "--allow-all-tools"))
    end)

    it("maps plan to --plan plus --allow-all-tools", function()
      local cmd = Builder.build("hi", { permission_mode = "plan" }, nil, {})
      assert.is_true(contains(cmd, "--plan"))
      assert.is_true(contains(cmd, "--allow-all-tools"))
    end)

    it("expands the deny list into --deny-tool flags", function()
      local cmd = Builder.build("hi", {
        permission_mode = "acceptEdits",
        permissions_deny = { "Bash", "Write" },
      }, nil, {})
      assert.is_true(contains(cmd, "--allow-all-tools"))
      assert.is_true(contains(cmd, "--deny-tool"))
      assert.is_true(contains(cmd, "shell()"))
      assert.is_true(contains(cmd, "write()"))
    end)

    it("ignores the deny list under bypassPermissions", function()
      local cmd = Builder.build("hi", {
        permission_mode = "bypassPermissions",
        permissions_deny = { "Bash" },
      }, nil, {})
      assert.is_false(contains(cmd, "--deny-tool"))
    end)

    it("prefixes context files for a new session", function()
      local cmd = Builder.build("hi", { context = { "@file:lua/init.lua" } }, nil, {})
      assert.are.equal("Context file: lua/init.lua\n\nhi", cmd[#cmd])
    end)

    it("omits the context prefix when resuming", function()
      local cmd = Builder.build("hi", { context = { "@file:lua/init.lua" } }, "sess-1", {})
      assert.are.equal("hi", cmd[#cmd])
    end)

    it("prefixes a language instruction", function()
      local cmd = Builder.build("hi", { language = "ja" }, nil, {})
      assert.are.equal("Always respond in Japanese (ja).\n\nhi", cmd[#cmd])
    end)

    it("skips the language instruction for en", function()
      local cmd = Builder.build("hi", { language = "en" }, nil, {})
      assert.are.equal("hi", cmd[#cmd])
    end)
  end)
end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_command_builder_spec.lua"`

Expected: FAIL — `module 'vibing.infrastructure.adapter.modules.copilot_command_builder' not found`

- [ ] **Step 3: 実装を書く**

`lua/vibing/infrastructure/adapter/modules/copilot_command_builder.lua` を新規作成する。

```lua
--- Copilot CLI command builder for `copilot -p --output-format json` execution
--- Builds the command array for the GitHub Copilot CLI with JSONL output
--- @module vibing.infrastructure.adapter.modules.copilot_command_builder

local Modes = require("vibing.core.constants.modes")

local M = {}

local cached_copilot_path = nil

--- Override the resolved executable path. Test seam only.
--- @param path string|nil
function M._set_executable_path(path)
  cached_copilot_path = path
end

--- Resolve model name from opts or config
--- Claude short names (sonnet/opus/haiku/fable) are not valid copilot model ids,
--- so they are dropped and copilot's own default is used instead.
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_model(opts, config)
  local model = opts.model or (config.agent and config.agent.default_model)
  if model and Modes.is_valid_model(model) then
    return nil
  end
  return model
end

--- Resolve language setting
--- @param opts Vibing.AdapterOpts
--- @param config Vibing.Config
--- @return string|nil
local function resolve_language(opts, config)
  local language = opts.language
  if not language and config.language then
    if type(config.language) == "table" then
      language = config.language.default or config.language.chat
    else
      language = config.language
    end
  end
  return type(language) == "string" and language or nil
end

--- Build context prefix for the prompt
--- @param opts Vibing.AdapterOpts
--- @return string context_prefix Empty string if no context
local function build_context_prefix(opts)
  local parts = {}
  for _, ctx in ipairs(opts.context or {}) do
    if ctx:match("^@file:") then
      table.insert(parts, string.format("Context file: %s", ctx:sub(7)))
    end
  end
  if #parts == 0 then
    return ""
  end
  return table.concat(parts, "\n") .. "\n\n"
end

--- Map a vibing permission entry to a copilot permission pattern
--- @param entry string
--- @return string|nil
function M.to_deny_pattern(entry)
  local bash_pattern = entry:match("^Bash%((.+)%)$")
  if bash_pattern then
    return string.format("shell(%s)", bash_pattern)
  end
  if entry == "Bash" then
    return "shell()"
  end
  if entry == "Write" or entry == "Edit" then
    return "write()"
  end
  if entry == "WebFetch" or entry == "WebSearch" then
    return "url()"
  end
  return nil
end

--- Convert a deny list into deduplicated copilot patterns, preserving input order
--- @param deny string[]|nil
--- @return string[]
function M.build_deny_patterns(deny)
  local patterns, seen = {}, {}
  for _, entry in ipairs(deny or {}) do
    local pattern = M.to_deny_pattern(entry)
    if pattern and not seen[pattern] then
      seen[pattern] = true
      table.insert(patterns, pattern)
    end
  end
  return patterns
end

--- Append permission flags. copilot's non-interactive mode requires --allow-all-tools,
--- so denies are expressed with --deny-tool rather than an allow list.
--- @param cmd string[]
--- @param opts Vibing.AdapterOpts
local function append_permission_flags(cmd, opts)
  local permission_mode = opts.permission_mode or "default"

  if permission_mode == "bypassPermissions" then
    table.insert(cmd, "--allow-all")
    return
  end

  if permission_mode == "plan" then
    table.insert(cmd, "--plan")
  end
  table.insert(cmd, "--allow-all-tools")

  for _, pattern in ipairs(M.build_deny_patterns(opts.permissions_deny)) do
    table.insert(cmd, "--deny-tool")
    table.insert(cmd, pattern)
  end
end

--- Build the `copilot -p --output-format json` command array
--- @param prompt string User prompt
--- @param opts Vibing.AdapterOpts Adapter options
--- @param session_id string|nil Session ID for resumption
--- @param config Vibing.Config Plugin config
--- @return string[] Command array for vim.system()
function M.build(prompt, opts, session_id, config)
  if not cached_copilot_path then
    cached_copilot_path = vim.fn.exepath("copilot")
    if cached_copilot_path == "" then
      cached_copilot_path = nil
      error("Copilot CLI not found in PATH. Please install GitHub Copilot CLI.")
    end
  end

  local cmd = { cached_copilot_path, "--output-format", "json", "--stream", "on", "--no-color" }

  if session_id then
    table.insert(cmd, "--resume=" .. session_id)
  end

  local model = resolve_model(opts, config)
  if model then
    table.insert(cmd, "--model")
    table.insert(cmd, model)
  end

  append_permission_flags(cmd, opts)

  local full_prompt = prompt
  if not session_id then
    full_prompt = build_context_prefix(opts) .. prompt
  end

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      full_prompt = string.format("Always respond in %s (%s).\n\n%s", lang_name, language, full_prompt)
    end
  end

  table.insert(cmd, "-p")
  table.insert(cmd, full_prompt)

  return cmd
end

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_command_builder_spec.lua"`

Expected: PASS（全 21 ケース）

- [ ] **Step 5: Lua 構文チェックを実行する**

Run: `pnpm run check`

Expected: エラーなし

- [ ] **Step 6: コミット**

```bash
git add lua/vibing/infrastructure/adapter/modules/copilot_command_builder.lua \
        tests/copilot_command_builder_spec.lua
git commit -m "feat(copilot): add command builder for copilot CLI backend"
```

---

### Task 2: ツール表示フォーマッタ

copilot の `tool.execution_start` / `tool.execution_complete` ペイロードをチャットバッファ向けの
Markdown 断片に整形する。マーカー設定と表示モードのキャッシュ取得は `tool_display.lua` に
共有ヘルパーとして切り出し、`codex_item_display.lua` の同等コードもそこへ委譲させる。

**Files:**

- Modify: `lua/vibing/infrastructure/adapter/modules/tool_display.lua`（共有ヘルパーを追加）
- Modify: `lua/vibing/infrastructure/adapter/modules/codex_item_display.lua:117-133`（委譲に置換）
- Create: `lua/vibing/infrastructure/adapter/modules/copilot_item_display.lua`
- Test: `tests/copilot_item_display_spec.lua`

**Interfaces:**

- Consumes: `ToolDisplay.resolve_marker(tool_name, markers)`,
  `ToolDisplay.format_result_text(result_text, display_mode)`
- Produces:
  - `ToolDisplay.get_cached_markers(context) -> table|nil`
  - `ToolDisplay.get_cached_display_mode(context) -> string`
  - `M.resolve_label(tool_name) -> string`
  - `M.summarize_arguments(args) -> string summary, string kind`（`kind` は
    `"command"` / `"path"` / `"other"`）
  - `M.extract_result_text(data) -> string`
  - `M.format_execution_start(data, context) -> string`
  - `M.format_execution_complete(data, context) -> string`

- [ ] **Step 1: 失敗するテストを書く**

`tests/copilot_item_display_spec.lua` を新規作成する。

```lua
local ItemDisplay = require("vibing.infrastructure.adapter.modules.copilot_item_display")

describe("copilot_item_display", function()
  ---表示モードを固定した context を作る
  ---@return table
  local function make_context()
    return { _cached_markers = false, _cached_display_mode = "full" }
  end

  describe("resolve_label", function()
    it("maps bash to Bash", function()
      assert.are.equal("Bash", ItemDisplay.resolve_label("bash"))
    end)

    it("returns unknown tool names unchanged", function()
      assert.are.equal("some_future_tool", ItemDisplay.resolve_label("some_future_tool"))
    end)
  end)

  describe("summarize_arguments", function()
    it("prefers command and reports the command kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ command = "ls -la", description = "x" })
      assert.are.equal("ls -la", summary)
      assert.are.equal("command", kind)
    end)

    it("uses path and reports the path kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ path = "lua/init.lua" })
      assert.are.equal("lua/init.lua", summary)
      assert.are.equal("path", kind)
    end)

    it("uses file_path and reports the path kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ file_path = "a/b.lua" })
      assert.are.equal("a/b.lua", summary)
      assert.are.equal("path", kind)
    end)

    it("falls back to encoded json with the other kind", function()
      local summary, kind = ItemDisplay.summarize_arguments({ query = "vibing" })
      assert.are.equal("other", kind)
      assert.is_true(summary:find("vibing", 1, true) ~= nil)
    end)

    it("returns an empty summary for nil", function()
      local summary, kind = ItemDisplay.summarize_arguments(nil)
      assert.are.equal("", summary)
      assert.are.equal("other", kind)
    end)
  end)

  describe("extract_result_text", function()
    it("reads a string result", function()
      assert.are.equal("done", ItemDisplay.extract_result_text({ result = "done" }))
    end)

    it("reads result.content", function()
      assert.are.equal("hello\n", ItemDisplay.extract_result_text({ result = { content = "hello\n" } }))
    end)

    it("reads the error field when there is no result", function()
      assert.are.equal("boom", ItemDisplay.extract_result_text({ error = "boom" }))
    end)

    it("returns an empty string with no usable field", function()
      assert.are.equal("", ItemDisplay.extract_result_text({}))
    end)
  end)

  describe("format_execution_start", function()
    it("renders a header with the label and summary", function()
      local text = ItemDisplay.format_execution_start({
        toolName = "bash",
        arguments = { command = "ls -la" },
      }, make_context())
      assert.are.equal("\n⏺ Bash(ls -la)\n", text)
    end)

    it("renders unknown tools with their raw name", function()
      local text = ItemDisplay.format_execution_start({
        toolName = "future_tool",
        arguments = { path = "x.lua" },
      }, make_context())
      assert.are.equal("\n⏺ future_tool(x.lua)\n", text)
    end)
  end)

  describe("format_execution_complete", function()
    it("renders the result body", function()
      local text = ItemDisplay.format_execution_complete({
        success = true,
        result = { content = "hello" },
      }, make_context())
      assert.are.equal("  ⎿  hello\n", text)
    end)

    it("prefixes Error when the tool failed", function()
      local text = ItemDisplay.format_execution_complete({
        success = false,
        error = "permission denied",
      }, make_context())
      assert.are.equal("  ⎿  Error: permission denied\n", text)
    end)

    it("returns an empty string when there is nothing to show", function()
      local text = ItemDisplay.format_execution_complete({ success = true }, make_context())
      assert.are.equal("", text)
    end)
  end)
end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_item_display_spec.lua"`

Expected: FAIL — `module 'vibing.infrastructure.adapter.modules.copilot_item_display' not found`

- [ ] **Step 3: 共有ヘルパーを `tool_display.lua` に追加する**

`lua/vibing/infrastructure/adapter/modules/tool_display.lua` の `return M` の直前に追加する。

```lua
--- Get tool markers config, cached on the per-stream processing context
--- @param context table
--- @return table|nil
function M.get_cached_markers(context)
  if context._cached_markers == nil then
    context._cached_markers = M.get_markers_config() or false
  end
  return context._cached_markers or nil
end

--- Get the tool result display mode, cached on the per-stream processing context
--- @param context table
--- @return string
function M.get_cached_display_mode(context)
  if not context._cached_display_mode then
    context._cached_display_mode = M.get_display_mode()
  end
  return context._cached_display_mode
end
```

- [ ] **Step 4: `codex_item_display.lua` を共有ヘルパーに委譲させる**

`lua/vibing/infrastructure/adapter/modules/codex_item_display.lua:117-133` の 2 つの関数本体を
置き換える（関数名と呼び出し側はそのまま）。

```lua
--- @param context table
--- @return table|nil
function M._get_markers(context)
  return ToolDisplay.get_cached_markers(context)
end

--- @param context table
--- @return string
function M._get_display_mode(context)
  return ToolDisplay.get_cached_display_mode(context)
end
```

- [ ] **Step 5: `copilot_item_display.lua` を実装する**

```lua
--- Display helpers for copilot tool execution events
--- Formats tool.execution_start / tool.execution_complete payloads
--- @module vibing.infrastructure.adapter.modules.copilot_item_display

local ToolDisplay = require("vibing.infrastructure.adapter.modules.tool_display")

local M = {}

local ARGUMENT_SUMMARY_LIMIT = 100

--- copilot tool names that map onto a vibing-style display label.
--- Names absent here are displayed verbatim; extend as more are confirmed on real runs.
local TOOL_LABELS = {
  bash = "Bash",
}

--- Map a copilot tool name to its display label
--- @param tool_name string
--- @return string
function M.resolve_label(tool_name)
  return TOOL_LABELS[tool_name] or tool_name
end

--- Summarize tool arguments for the header
--- @param args table|nil
--- @return string summary
--- @return string kind "command"|"path"|"other"
function M.summarize_arguments(args)
  if type(args) ~= "table" then
    return "", "other"
  end
  if type(args.command) == "string" then
    return args.command, "command"
  end
  if type(args.path) == "string" then
    return args.path, "path"
  end
  if type(args.file_path) == "string" then
    return args.file_path, "path"
  end

  local ok, encoded = pcall(vim.json.encode, args)
  if not ok then
    return "", "other"
  end
  if #encoded > ARGUMENT_SUMMARY_LIMIT then
    return encoded:sub(1, ARGUMENT_SUMMARY_LIMIT) .. "...", "other"
  end
  return encoded, "other"
end

--- Extract displayable text from a tool.execution_complete payload
--- @param data table
--- @return string
function M.extract_result_text(data)
  local result = data.result
  if type(result) == "string" then
    return result
  end
  if type(result) == "table" then
    if type(result.content) == "string" then
      return result.content
    end
    local ok, encoded = pcall(vim.json.encode, result)
    return ok and encoded or ""
  end
  if data.error then
    return tostring(data.error)
  end
  return ""
end

--- Format the header emitted when a tool starts executing
--- @param data table tool.execution_start payload
--- @param context table
--- @return string
function M.format_execution_start(data, context)
  local markers = ToolDisplay.get_cached_markers(context)
  local label = M.resolve_label(data.toolName or "tool")
  local marker = ToolDisplay.resolve_marker(label, markers)
  local summary = M.summarize_arguments(data.arguments)
  return string.format("\n%s %s(%s)\n", marker, label, summary)
end

--- Format the result emitted when a tool finishes executing
--- @param data table tool.execution_complete payload
--- @param context table
--- @return string
function M.format_execution_complete(data, context)
  local text = M.extract_result_text(data)
  if text ~= "" and data.success == false then
    text = "Error: " .. text
  end
  return ToolDisplay.format_result_text(text, ToolDisplay.get_cached_display_mode(context))
end

return M
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_item_display_spec.lua"`

Expected: PASS（全 16 ケース）

- [ ] **Step 7: 既存テストが壊れていないことを確認する**

Run: `pnpm run test:lua`

Expected: 既存の spec がすべて PASS（`codex_item_display.lua` の委譲リファクタによる回帰がないこと）

- [ ] **Step 8: コミット**

```bash
git add lua/vibing/infrastructure/adapter/modules/tool_display.lua \
        lua/vibing/infrastructure/adapter/modules/codex_item_display.lua \
        lua/vibing/infrastructure/adapter/modules/copilot_item_display.lua \
        tests/copilot_item_display_spec.lua
git commit -m "feat(copilot): add tool display formatter and share marker cache helpers"
```

---

### Task 3: イベントプロセッサ

`copilot --output-format json` の JSONL を 1 行ずつ処理し、chunk 出力・ツール表示・
セッション ID 保存にディスパッチする。

**Files:**

- Create: `lua/vibing/infrastructure/adapter/modules/copilot_event_processor.lua`
- Test: `tests/copilot_event_processor_spec.lua`

**Interfaces:**

- Consumes: Task 2 の `copilot_item_display` の全関数、
  `SessionManagerModule.new()` / `SessionManagerModule.store(self, handle_id, session_id)` /
  `SessionManagerModule.get(self, handle_id)`
- Produces: `M.processLine(line, context) -> boolean` — `stream_handler.create_stdout_handler` が
  期待する `eventProcessor` インターフェース。`context` は以下のフィールドを持つ:
  `sessionManager`, `handleId`, `opts`, `output`, `errorOutput`, `onFirstResponse`, `onChunk`

- [ ] **Step 1: 失敗するテストを書く**

`tests/copilot_event_processor_spec.lua` を新規作成する。

```lua
local Processor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local SessionManager = require("vibing.infrastructure.adapter.modules.session_manager")

describe("copilot_event_processor", function()
  local context

  before_each(function()
    context = {
      sessionManager = SessionManager.new(),
      handleId = "handle-1",
      opts = {},
      output = {},
      errorOutput = {},
      _cached_markers = false,
      _cached_display_mode = "full",
    }
  end)

  ---イベントを JSON 行にして処理する
  ---@param event table
  local function process(event)
    Processor.processLine(vim.json.encode(event), context)
  end

  ---output バッファを連結して返す
  ---@return string
  local function output_text()
    return table.concat(context.output, "")
  end

  it("ignores blank and malformed lines", function()
    assert.is_false(Processor.processLine("", context))
    assert.is_false(Processor.processLine("not json", context))
  end)

  it("fires onFirstResponse on assistant.turn_start", function()
    local fired = false
    context.onFirstResponse = function()
      fired = true
    end
    process({ type = "assistant.turn_start", data = { turnId = "0" } })
    assert.is_true(fired)
  end)

  it("emits delta content in order", function()
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "he" } })
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "llo" } })
    assert.are.equal("hello", output_text())
  end)

  it("does not re-emit a message whose deltas were already streamed", function()
    process({ type = "assistant.message_delta", data = { messageId = "m1", deltaContent = "hello" } })
    process({ type = "assistant.message", data = { messageId = "m1", content = "hello" } })
    assert.are.equal("hello", output_text())
  end)

  it("emits assistant.message content when no delta arrived", function()
    process({ type = "assistant.message", data = { messageId = "m2", content = "hello" } })
    assert.are.equal("hello", output_text())
  end)

  it("ignores an assistant.message with empty content", function()
    process({ type = "assistant.message", data = { messageId = "m3", content = "" } })
    assert.are.equal("", output_text())
  end)

  it("stores the session id from the result event", function()
    process({ type = "result", sessionId = "sess-abc", exitCode = 0 })
    assert.are.equal("sess-abc", SessionManager.get(context.sessionManager, "handle-1"))
  end)

  it("renders tool execution start and complete", function()
    process({
      type = "tool.execution_start",
      data = { toolCallId = "t1", toolName = "bash", arguments = { command = "ls" } },
    })
    process({
      type = "tool.execution_complete",
      data = { toolCallId = "t1", success = true, result = { content = "a.txt" } },
    })
    assert.are.equal("\n⏺ Bash(ls)\n  ⎿  a.txt\n", output_text())
  end)

  it("reports a bash tool call through on_tool_use as a command", function()
    local seen = nil
    context.opts.on_tool_use = function(tool, file_path, command)
      seen = { tool = tool, file_path = file_path, command = command }
    end
    process({
      type = "tool.execution_start",
      data = { toolName = "bash", arguments = { command = "ls -la" } },
    })
    vim.wait(100, function()
      return seen ~= nil
    end, 10)
    assert.are.same({ tool = "Bash", file_path = nil, command = "ls -la" }, seen)
  end)

  it("reports a path-shaped tool call through on_tool_use as a file path", function()
    local seen = nil
    context.opts.on_tool_use = function(tool, file_path, command)
      seen = { tool = tool, file_path = file_path, command = command }
    end
    process({
      type = "tool.execution_start",
      data = { toolName = "edit_file", arguments = { path = "lua/init.lua" } },
    })
    vim.wait(100, function()
      return seen ~= nil
    end, 10)
    assert.are.same({ tool = "edit_file", file_path = "lua/init.lua", command = nil }, seen)
  end)

  it("collects error events into errorOutput", function()
    process({ type = "error", data = { message = "rate limited" } })
    assert.are.equal("rate limited", table.concat(context.errorOutput, ""))
  end)

  it("ignores unrelated event types", function()
    assert.is_true(Processor.processLine(
      vim.json.encode({ type = "session.mcp_server_status_changed", data = {} }),
      context
    ))
    assert.are.equal("", output_text())
  end)
end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_event_processor_spec.lua"`

Expected: FAIL — `module 'vibing.infrastructure.adapter.modules.copilot_event_processor' not found`

- [ ] **Step 3: 実装を書く**

`lua/vibing/infrastructure/adapter/modules/copilot_event_processor.lua` を新規作成する。

```lua
--- Copilot CLI event processor for `copilot --output-format json` output
--- Processes JSONL events from the Copilot CLI and dispatches to callbacks
--- @module vibing.infrastructure.adapter.modules.copilot_event_processor

local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ItemDisplay = require("vibing.infrastructure.adapter.modules.copilot_item_display")

local M = {}

--- Emit formatted text to output and the onChunk callback
--- @param text string|nil
--- @param context table
local function emit_chunk(text, context)
  if not text or text == "" then
    return
  end
  table.insert(context.output, text)
  if context.onChunk then
    vim.schedule(function()
      context.onChunk(text)
    end)
  end
end

--- Notify opts.on_tool_use for a starting tool call
--- @param data table
--- @param context table
local function notify_tool_use(data, context)
  if not context.opts or not context.opts.on_tool_use then
    return
  end

  local label = ItemDisplay.resolve_label(data.toolName or "tool")
  local summary, kind = ItemDisplay.summarize_arguments(data.arguments)
  local file_path = kind == "path" and summary or nil
  local command = kind ~= "path" and summary or nil

  vim.schedule(function()
    context.opts.on_tool_use(label, file_path, command)
  end)
end

--- Event handler dispatch table
local event_handlers = {
  ["assistant.turn_start"] = function(_, context)
    if context.onFirstResponse then
      context.onFirstResponse()
    end
    return true
  end,

  ["assistant.message_delta"] = function(msg, context)
    local data = msg.data or {}
    if data.messageId then
      context._streamed_messages = context._streamed_messages or {}
      context._streamed_messages[data.messageId] = true
    end
    emit_chunk(data.deltaContent, context)
    return true
  end,

  -- Fallback for runs where streaming deltas never arrive (e.g. `--stream off`
  -- forced by user config): emit the whole message only if nothing was streamed.
  ["assistant.message"] = function(msg, context)
    local data = msg.data or {}
    local streamed = context._streamed_messages and data.messageId
      and context._streamed_messages[data.messageId]
    if not streamed then
      emit_chunk(data.content, context)
    end
    return true
  end,

  ["tool.execution_start"] = function(msg, context)
    local data = msg.data or {}
    emit_chunk(ItemDisplay.format_execution_start(data, context), context)
    notify_tool_use(data, context)
    return true
  end,

  ["tool.execution_complete"] = function(msg, context)
    emit_chunk(ItemDisplay.format_execution_complete(msg.data or {}, context), context)
    return true
  end,

  ["result"] = function(msg, context)
    if msg.sessionId and context.sessionManager and context.handleId then
      SessionManagerModule.store(context.sessionManager, context.handleId, msg.sessionId)
    end
    return true
  end,

  ["error"] = function(msg, context)
    local message = msg.message or (msg.data and msg.data.message)
    if message then
      table.insert(context.errorOutput, tostring(message))
    end
    return true
  end,
}

--- Process a single JSON line from the Copilot CLI output
--- @param line string JSON string
--- @param context table Processing context
--- @return boolean success Whether the line was processed
function M.processLine(line, context)
  if line == "" or not context then
    return false
  end

  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" or not msg.type then
    return false
  end

  local handler = event_handlers[msg.type]
  if handler then
    return handler(msg, context)
  end

  return true
end

return M
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_event_processor_spec.lua"`

Expected: PASS（全 12 ケース）

- [ ] **Step 5: コミット**

```bash
git add lua/vibing/infrastructure/adapter/modules/copilot_event_processor.lua \
        tests/copilot_event_processor_spec.lua
git commit -m "feat(copilot): add JSONL event processor for copilot CLI backend"
```

---

### Task 4: アダプター本体

`Base` を継承した `CopilotCLI` アダプター。`vim.system()` でプロセスを起動し、Task 1〜3 の
モジュールを束ねる。

**Files:**

- Create: `lua/vibing/infrastructure/adapter/copilot_cli.lua`
- Test: `tests/copilot_cli_spec.lua`

**Interfaces:**

- Consumes: Task 1 の `CopilotCommandBuilder.build`、Task 3 の `CopilotEventProcessor.processLine`、
  既存の `StreamHandler.create_stdout_handler` / `create_stderr_handler` / `create_exit_handler`、
  `SessionManagerModule`、`ActiveStreamRegistry.register` / `unregister`
- Produces: `CopilotCLI:new(config)`, `:execute(prompt, opts)`, `:stream(prompt, opts, on_chunk,
on_done) -> handle_id`, `:cancel(handle_id)`, `:supports(feature)`,
  `:set_session_id(session_id, handle_id)`, `:get_session_id(handle_id)`,
  `:cleanup_session(handle_id)`, `:cleanup_stale_sessions()`。`instance.name` は `"copilot_cli"`

`ActiveStreamRegistry` への登録は必須。RPC ハンドラの `nvim_ask_user_question`
(`infrastructure/rpc/handlers/permission.lua:277`) が `get_by_chat_file_path` →
「唯一の登録ストリーム」へのフォールバックで解決するため、未登録だと copilot セッションで
`mcp__vibing-nvim__nvim_ask_user_question` が動かない。

copilot は成功時に stderr へ何も書かないことを実機確認済みなので、codex のような stderr
フィルタは不要で `StreamHandler.create_stderr_handler` をそのまま使える。

- [ ] **Step 1: 失敗するテストを書く**

`tests/copilot_cli_spec.lua` を新規作成する。

```lua
describe("copilot_cli adapter", function()
  local CopilotCLI

  before_each(function()
    package.loaded["vibing.infrastructure.adapter.copilot_cli"] = nil
    CopilotCLI = require("vibing.infrastructure.adapter.copilot_cli")
  end)

  it("creates an instance named copilot_cli", function()
    local adapter = CopilotCLI:new({})
    assert.are.equal("copilot_cli", adapter.name)
  end)

  it("declares its supported features", function()
    local adapter = CopilotCLI:new({})
    assert.is_true(adapter:supports("streaming"))
    assert.is_true(adapter:supports("tools"))
    assert.is_true(adapter:supports("model_selection"))
    assert.is_true(adapter:supports("context"))
    assert.is_true(adapter:supports("session"))
    assert.is_false(adapter:supports("nonexistent_feature"))
  end)

  it("round-trips a session id per handle", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:set_session_id("sess-2", "handle-b")
    assert.are.equal("sess-1", adapter:get_session_id("handle-a"))
    assert.are.equal("sess-2", adapter:get_session_id("handle-b"))
  end)

  it("clears a session id on cleanup_session", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:cleanup_session("handle-a")
    assert.is_nil(adapter:get_session_id("handle-a"))
  end)

  it("drops sessions with no live handle on cleanup_stale_sessions", function()
    local adapter = CopilotCLI:new({})
    adapter:set_session_id("sess-1", "handle-a")
    adapter:cleanup_stale_sessions()
    assert.is_nil(adapter:get_session_id("handle-a"))
  end)

  it("does not error when cancelling an unknown handle", function()
    local adapter = CopilotCLI:new({})
    assert.has_no.errors(function()
      adapter:cancel("no-such-handle")
    end)
  end)
end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_cli_spec.lua"`

Expected: FAIL — `module 'vibing.infrastructure.adapter.copilot_cli' not found`

- [ ] **Step 3: 実装を書く**

`lua/vibing/infrastructure/adapter/copilot_cli.lua` を新規作成する。

```lua
--- Copilot CLI adapter
--- Uses `copilot -p --output-format json` for communication
--- @module vibing.infrastructure.adapter.copilot_cli

local Base = require("vibing.infrastructure.adapter.base")
local CopilotCommandBuilder = require("vibing.infrastructure.adapter.modules.copilot_command_builder")
local CopilotEventProcessor = require("vibing.infrastructure.adapter.modules.copilot_event_processor")
local StreamHandler = require("vibing.infrastructure.adapter.modules.stream_handler")
local SessionManagerModule = require("vibing.infrastructure.adapter.modules.session_manager")
local ActiveStreamRegistry = require("vibing.infrastructure.adapter.modules.active_stream_registry")

---@class Vibing.CopilotCLIAdapter : Vibing.Adapter
---@field _handles table<string, table>
---@field _session_manager table
local CopilotCLI = setmetatable({}, { __index = Base })
CopilotCLI.__index = CopilotCLI

local INITIAL_RESPONSE_TIMEOUT_MS = 120000

local SUPPORTED_FEATURES = {
  streaming = true,
  tools = true,
  model_selection = true,
  context = true,
  session = true,
}

---@param config Vibing.Config
---@return Vibing.CopilotCLIAdapter
function CopilotCLI:new(config)
  local instance = Base.new(self, config)
  setmetatable(instance, CopilotCLI)
  instance.name = "copilot_cli"
  instance._handles = {}
  instance._session_manager = SessionManagerModule.new()
  math.randomseed(vim.loop.hrtime())
  return instance
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@return Vibing.Response
function CopilotCLI:execute(prompt, opts)
  opts = opts or {}
  local result = { content = "" }
  local done = false

  self:stream(prompt, opts, function(chunk)
    result.content = result.content .. chunk
  end, function(response)
    if response.error then
      result.error = response.error
    end
    done = true
  end)

  vim.wait(120000, function()
    return done
  end, 100)
  return result
end

---@param prompt string
---@param opts Vibing.AdapterOpts
---@param on_chunk fun(chunk: string)
---@param on_done fun(response: Vibing.Response)
---@return string handle_id
function CopilotCLI:stream(prompt, opts, on_chunk, on_done)
  opts = opts or {}

  local debug_mode = vim.g.vibing_debug_stream
  local handle_id = string.format("%016x_%x", vim.loop.hrtime(), math.random(100000))
  local session_id = opts._session_id

  local cmd = CopilotCommandBuilder.build(prompt, opts, session_id, self.config)
  local output = {}
  local error_output = {}

  local received_first_response = false
  local timeout_timer = nil
  local completed = false

  local function cancel_timeout()
    received_first_response = true
    if timeout_timer then
      vim.fn.timer_stop(timeout_timer)
      timeout_timer = nil
    end
  end

  local event_context = {
    sessionManager = self._session_manager,
    handleId = handle_id,
    opts = opts,
    output = output,
    errorOutput = error_output,
    onFirstResponse = cancel_timeout,
    onChunk = function(chunk)
      cancel_timeout()
      on_chunk(chunk, handle_id)
    end,
  }

  local env = vim.fn.environ()

  local rpc_server = require("vibing.infrastructure.rpc.server")
  local rpc_port = rpc_server.get_port()
  if rpc_port then
    local port_str = tostring(rpc_port)
    env.VIBING_NVIM_RPC_PORT = port_str
    env.VIBING_RPC_PORT = port_str
    env.VIBING_NVIM_CONTEXT = "true"
  end
  env.VIBING_HANDLE_ID = handle_id

  -- Required so nvim_ask_user_question can resolve this stream's chat callbacks
  -- (see rpc/handlers/permission.lua and ActiveStreamRegistry).
  ActiveStreamRegistry.register({
    handle_id = handle_id,
    adapter = self,
    on_insert_choices = opts.on_insert_choices,
    on_approval_required = opts.on_approval_required,
  })

  local wrapped_on_done = function(response)
    if not completed then
      completed = true
      ActiveStreamRegistry.unregister(handle_id)
      if timeout_timer then
        vim.fn.timer_stop(timeout_timer)
        timeout_timer = nil
      end
      on_done(response)
    end
  end

  self._handles[handle_id] = vim.system(cmd, {
    text = true,
    stdin = "",
    cwd = opts.cwd or vim.fn.getcwd(),
    env = env,
    stdout = StreamHandler.create_stdout_handler(CopilotEventProcessor, event_context, function()
      return self._handles[handle_id] == nil
    end),
    stderr = StreamHandler.create_stderr_handler(error_output),
  }, StreamHandler.create_exit_handler(handle_id, self._handles, output, error_output, wrapped_on_done))

  if debug_mode then
    local pid = self._handles[handle_id] and self._handles[handle_id].pid or "unknown"
    vim.notify(string.format("[vibing:copilot] Process started: pid=%s", tostring(pid)), vim.log.levels.INFO)
    vim.notify(
      string.format("[vibing:copilot] Command: %s", table.concat(cmd, " "):sub(1, 200)),
      vim.log.levels.DEBUG
    )
  end

  -- Session corruption detection timeout
  if session_id then
    timeout_timer = vim.fn.timer_start(INITIAL_RESPONSE_TIMEOUT_MS, function()
      if not received_first_response and not completed and self._handles[handle_id] then
        vim.schedule(function()
          if not completed then
            vim.notify(
              "[vibing] Session resume timeout - killing hung process and resetting session",
              vim.log.levels.WARN
            )
            self:cancel(handle_id)
            wrapped_on_done({
              error = "Session resume timeout",
              _session_corrupted = true,
              _old_session_id = session_id,
              _handle_id = handle_id,
            })
          end
        end)
      end
    end)
  end

  return handle_id
end

---@param handle_id string?
function CopilotCLI:cancel(handle_id)
  -- copilot's shell tool spawns children that inherit the stdout pipe. Killing only
  -- the parent leaves them holding it open, so vim.system()'s exit handler never fires
  -- and the chat UI stays frozen. Kill children first, then the parent.
  local function kill_process(handle)
    if not handle then
      return
    end
    local pid = handle.pid
    if not pid or pid <= 0 then
      return
    end
    vim.fn.system(string.format("pkill -9 -P %d 2>/dev/null; true", pid))
    pcall(function()
      handle:kill(9)
    end)
  end

  if handle_id then
    local handle = self._handles[handle_id]
    if handle then
      kill_process(handle)
      self._handles[handle_id] = nil
    end
  else
    for id, handle in pairs(self._handles) do
      kill_process(handle)
      self._handles[id] = nil
    end
  end
end

---@param feature string
---@return boolean
function CopilotCLI:supports(feature)
  return SUPPORTED_FEATURES[feature] or false
end

---@param session_id string?
---@param handle_id string?
function CopilotCLI:set_session_id(session_id, handle_id)
  SessionManagerModule.set(self._session_manager, session_id, handle_id)
end

---@param handle_id string?
---@return string?
function CopilotCLI:get_session_id(handle_id)
  return SessionManagerModule.get(self._session_manager, handle_id)
end

---@param handle_id string
function CopilotCLI:cleanup_session(handle_id)
  SessionManagerModule.cleanup(self._session_manager, handle_id)
end

function CopilotCLI:cleanup_stale_sessions()
  SessionManagerModule.cleanup_stale(self._session_manager, self._handles)
end

return CopilotCLI
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/copilot_cli_spec.lua"`

Expected: PASS（全 6 ケース）

- [ ] **Step 5: コミット**

```bash
git add lua/vibing/infrastructure/adapter/copilot_cli.lua tests/copilot_cli_spec.lua
git commit -m "feat(copilot): add copilot CLI adapter"
```

---

### Task 5: アダプターファクトリと登録

`init.lua` と `send_message.lua` に重複していた `claude` / `codex` 分岐をテーブル駆動の
factory に集約し、`copilot` を有効なエージェントとして登録する。

**Files:**

- Create: `lua/vibing/infrastructure/adapter/factory.lua`
- Modify: `lua/vibing/core/constants/modes.lua:15`
- Modify: `lua/vibing/init.lua:55-62`
- Modify: `lua/vibing/application/chat/send_message.lua:606-637`
- Modify: `lua/vibing/infrastructure/init.lua`
- Modify: `lua/vibing/config.lua:44`
- Test: `tests/adapter_factory_spec.lua`

**Interfaces:**

- Consumes: Task 4 の `vibing.infrastructure.adapter.copilot_cli`、既存の `claude_cli` / `codex_cli`
- Produces:
  - `Factory.create(agent_type, config) -> Vibing.Adapter` — 未知/nil の `agent_type` は
    `claude` にフォールバックする
  - `Factory.adapter_name(agent_type) -> string` — `"claude_cli"` / `"codex_cli"` / `"copilot_cli"`

- [ ] **Step 1: 失敗するテストを書く**

`tests/adapter_factory_spec.lua` を新規作成する。

```lua
local Factory = require("vibing.infrastructure.adapter.factory")
local Modes = require("vibing.core.constants.modes")

describe("adapter factory", function()
  describe("adapter_name", function()
    it("maps each agent type to its adapter name", function()
      assert.are.equal("claude_cli", Factory.adapter_name("claude"))
      assert.are.equal("codex_cli", Factory.adapter_name("codex"))
      assert.are.equal("copilot_cli", Factory.adapter_name("copilot"))
    end)

    it("falls back to claude_cli for unknown or nil agent types", function()
      assert.are.equal("claude_cli", Factory.adapter_name("nonexistent"))
      assert.are.equal("claude_cli", Factory.adapter_name(nil))
    end)
  end)

  describe("create", function()
    it("creates the adapter matching the agent type", function()
      assert.are.equal("claude_cli", Factory.create("claude", {}).name)
      assert.are.equal("codex_cli", Factory.create("codex", {}).name)
      assert.are.equal("copilot_cli", Factory.create("copilot", {}).name)
    end)

    it("falls back to the claude adapter for unknown agent types", function()
      assert.are.equal("claude_cli", Factory.create("nonexistent", {}).name)
      assert.are.equal("claude_cli", Factory.create(nil, {}).name)
    end)
  end)

  describe("VALID_AGENTS", function()
    it("accepts copilot as a valid agent", function()
      assert.is_true(Modes.is_valid_agent("copilot"))
      assert.is_true(Modes.is_valid_agent("claude"))
      assert.is_true(Modes.is_valid_agent("codex"))
      assert.is_false(Modes.is_valid_agent("nonexistent"))
    end)
  end)
end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/adapter_factory_spec.lua"`

Expected: FAIL — `module 'vibing.infrastructure.adapter.factory' not found`

- [ ] **Step 3: factory を実装する**

`lua/vibing/infrastructure/adapter/factory.lua` を新規作成する。

```lua
--- Adapter factory
--- Resolves an agent type ("claude" / "codex" / "copilot") to its adapter instance
--- @module vibing.infrastructure.adapter.factory

local M = {}

local ADAPTER_MODULES = {
  claude = "vibing.infrastructure.adapter.claude_cli",
  codex = "vibing.infrastructure.adapter.codex_cli",
  copilot = "vibing.infrastructure.adapter.copilot_cli",
}

local ADAPTER_NAMES = {
  claude = "claude_cli",
  codex = "codex_cli",
  copilot = "copilot_cli",
}

local DEFAULT_AGENT = "claude"

--- Get the adapter instance name for an agent type
--- @param agent_type string|nil
--- @return string
function M.adapter_name(agent_type)
  return ADAPTER_NAMES[agent_type] or ADAPTER_NAMES[DEFAULT_AGENT]
end

--- Create an adapter instance for an agent type
--- Unknown or nil agent types fall back to the claude adapter
--- @param agent_type string|nil
--- @param config Vibing.Config
--- @return Vibing.Adapter
function M.create(agent_type, config)
  local module_path = ADAPTER_MODULES[agent_type] or ADAPTER_MODULES[DEFAULT_AGENT]
  return require(module_path):new(config)
end

return M
```

- [ ] **Step 4: `modes.lua` に copilot を追加する**

`lua/vibing/core/constants/modes.lua:13-15` を置き換える。

```lua
---有効なエージェント（バックエンド）
---@type string[]
M.VALID_AGENTS = { "claude", "codex", "copilot" }
```

同ファイル 5 行目のコメントも実態に合わせて更新する。

```lua
---有効なモデル（claude 短縮名。codex/copilot 固有のモデル名は各 command_builder 側で自由入力を許可）
```

- [ ] **Step 5: `init.lua` を factory 経由に置き換える**

`lua/vibing/init.lua:55-62` の以下のブロック

```lua
  -- アダプターの初期化
  if M.config.adapter == "codex" then
    local CodexCLI = require("vibing.infrastructure.adapter.codex_cli")
    M.adapter = CodexCLI:new(M.config)
  else
    local ClaudeCLI = require("vibing.infrastructure.adapter.claude_cli")
    M.adapter = ClaudeCLI:new(M.config)
  end
```

を次に置き換える。

```lua
  -- アダプターの初期化
  local adapter_factory = require("vibing.infrastructure.adapter.factory")
  M.adapter = adapter_factory.create(M.config.adapter, M.config)
```

同ファイル 8 行目と 380 行目のコメント内の「claude_cli, codex_cli等」は
「claude_cli, codex_cli, copilot_cli等」に更新する。

- [ ] **Step 6: `send_message.lua` を factory 経由に置き換える**

`lua/vibing/application/chat/send_message.lua:606-637` の `M._resolve_adapter` の本体を
次に置き換える（関数シグネチャは変えない）。

```lua
function M._resolve_adapter(default_adapter, callbacks, config)
  local Modes = require("vibing.core.constants.modes")
  local adapter_factory = require("vibing.infrastructure.adapter.factory")
  local frontmatter = callbacks.parse_frontmatter()
  local agent_type = frontmatter and frontmatter.agent

  if not agent_type then
    return default_adapter
  end

  if not Modes.is_valid_agent(agent_type) then
    vim.notify(
      string.format("[vibing] Invalid agent '%s' in frontmatter; using default adapter", tostring(agent_type)),
      vim.log.levels.WARN
    )
    return default_adapter
  end

  if default_adapter and default_adapter.name == adapter_factory.adapter_name(agent_type) then
    return default_adapter
  end

  return adapter_factory.create(agent_type, config)
end
```

- [ ] **Step 7: `infrastructure/init.lua` にエクスポートを追加する**

`lua/vibing/infrastructure/init.lua` の `M.CodexCLIAdapter = ...` の直後に追加する。

```lua
M.CopilotCLIAdapter = require("vibing.infrastructure.adapter.copilot_cli")
```

- [ ] **Step 8: `config.lua` の型注釈を更新する**

`lua/vibing/config.lua:44` を置き換える。

```lua
---@field adapter? "claude"|"codex"|"copilot" バックエンドアダプター選択（デフォルト: "claude"）
```

- [ ] **Step 9: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/adapter_factory_spec.lua"`

Expected: PASS（全 5 ケース）

- [ ] **Step 10: 全 Lua テストと構文チェックを実行する**

Run: `pnpm run test:lua && pnpm run check`

Expected: すべて PASS。特に `tests/init_spec.lua` と `tests/chat_commands_spec.lua` が
factory 化による回帰を起こしていないこと。

- [ ] **Step 11: コミット**

```bash
git add lua/vibing/infrastructure/adapter/factory.lua \
        lua/vibing/core/constants/modes.lua \
        lua/vibing/init.lua \
        lua/vibing/application/chat/send_message.lua \
        lua/vibing/infrastructure/init.lua \
        lua/vibing/config.lua \
        tests/adapter_factory_spec.lua
git commit -m "feat(copilot): register copilot backend via a shared adapter factory"
```

---

### Task 6: フロントマター補完

チャットファイルのフロントマターで `agent: copilot` と copilot 用モデル名が補完されるようにする。

**Files:**

- Modify: `lua/vibing/infrastructure/completion/providers/frontmatter.lua:8-11,30-36,81-97`
- Modify: `lua/vibing/application/completion/sources/frontmatter.lua:11`（型注釈のみ）
- Test: `tests/completion/frontmatter_spec.lua`（ケース追加）

**Interfaces:**

- Consumes: なし（純粋なデータ追加）
- Produces: `M.get_model_values("copilot")` が 9 件の copilot モデル候補を返す。
  `M.get_enum_values("agent")` が 3 件を返し、3 件目が `copilot`

- [ ] **Step 1: 失敗するテストを書く**

`tests/completion/frontmatter_spec.lua` の `describe("Enum fields", ...)` ブロック内、
`it("should get model enum values via get_model_values", ...)` の直後に追加する。

```lua
    it("should include copilot in agent enum values", function()
      local items = frontmatter_provider.get_enum_values("agent")
      assert.are.equal(3, #items)
      assert.are.equal("claude", items[1].word)
      assert.are.equal("codex", items[2].word)
      assert.are.equal("copilot", items[3].word)
    end)

    it("should get copilot model values via get_model_values", function()
      local items = frontmatter_provider.get_model_values("copilot")
      assert.are.equal(9, #items)
      assert.are.equal("auto", items[1].word)
      assert.are.equal("claude-sonnet-5", items[2].word)
      assert.are.equal("Enum", items[1].kind)
    end)

    it("should fall back to claude models for an unknown agent", function()
      local items = frontmatter_provider.get_model_values("nonexistent")
      assert.are.equal(4, #items)
      assert.are.equal("haiku", items[1].word)
    end)
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/completion/frontmatter_spec.lua"`

Expected: FAIL — agent enum が 2 件しか返らない / copilot モデルが 4 件（claude のフォールバック）

- [ ] **Step 3: agent enum に copilot を追加する**

`lua/vibing/infrastructure/completion/providers/frontmatter.lua:8-11` を置き換える。

```lua
  agent = {
    { value = "claude", description = "Claude CLI (Anthropic)" },
    { value = "codex", description = "Codex CLI (OpenAI)" },
    { value = "copilot", description = "GitHub Copilot CLI" },
  },
```

- [ ] **Step 4: COPILOT_MODELS を追加してテーブル引きに変える**

同ファイル 30-36 行目の `CODEX_MODELS` 定義の直後に追加する。

```lua
--- copilot は 30 種類以上のモデルを持つため、代表的なものだけを候補に出す。
--- 実際に利用できるモデルは利用者のプランに依存するので、ここは候補提示であって検証ではない。
local COPILOT_MODELS = {
  { value = "auto", description = "Let Copilot pick the model" },
  { value = "claude-sonnet-5", description = "Claude Sonnet 5" },
  { value = "claude-opus-5", description = "Claude Opus 5" },
  { value = "claude-haiku-4.5", description = "Claude Haiku 4.5 (fastest)" },
  { value = "gpt-5.5", description = "GPT-5.5" },
  { value = "gpt-5.4", description = "GPT-5.4" },
  { value = "gpt-5.4-mini", description = "GPT-5.4 Mini" },
  { value = "gpt-5.3-codex", description = "GPT-5.3 Codex" },
  { value = "gemini-3.1-pro-preview", description = "Gemini 3.1 Pro (preview)" },
}

local MODELS_BY_AGENT = {
  claude = CLAUDE_MODELS,
  codex = CODEX_MODELS,
  copilot = COPILOT_MODELS,
}
```

- [ ] **Step 5: `get_model_values` をテーブル引きに置き換える**

同ファイル 81-85 行目を置き換える。

```lua
---Get model candidates for the given agent backend
---@param agent string? "claude" | "codex" | "copilot" (defaults to "claude")
---@return Vibing.CompletionItem[]
function M.get_model_values(agent)
  local models = MODELS_BY_AGENT[agent] or CLAUDE_MODELS
```

（関数の残りの本体は変更しない。）

- [ ] **Step 6: source 側の型注釈を更新する**

`lua/vibing/application/completion/sources/frontmatter.lua:11` を置き換える。

```lua
---@return string? "claude" | "codex" | "copilot" | nil
```

- [ ] **Step 7: テストが通ることを確認する**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/completion/frontmatter_spec.lua"`

Expected: PASS（既存ケース + 追加 3 ケース）

- [ ] **Step 8: コミット**

```bash
git add lua/vibing/infrastructure/completion/providers/frontmatter.lua \
        lua/vibing/application/completion/sources/frontmatter.lua \
        tests/completion/frontmatter_spec.lua
git commit -m "feat(copilot): complete copilot agent and models in chat frontmatter"
```

---

### Task 7: MCP 登録とドキュメント

`build.sh` で vibing-nvim MCP サーバーを copilot にも登録し、ユーザー向けドキュメントに
copilot バックエンドを記載する。

**Files:**

- Modify: `build.sh:215-225`
- Modify: `README.md:13,46-47,79,229,267,321-326,341-344,350,358,360,380`
- Modify: `README.ja.md:13,48,80,231,270,324-329,344-347,353,361,363,382`
- Modify: `docs/configuration.md:96-101`
- Modify: `doc/api-reference.md:27,416`

**Interfaces:**

- Consumes: Task 5 で登録済みの `adapter = "copilot"` / `agent: copilot`
- Produces: なし（ドキュメントとインストールスクリプトのみ）

- [ ] **Step 1: `build.sh` に copilot への MCP 登録を追加する**

`build.sh` の codex 登録ブロック（`# Register MCP server with codex (if available)` から
始まる `fi` まで）の直後に追加する。`MCP_SERVER_PATH` は codex ブロックで既に定義済みなので
再定義しない。

```bash
    # Register MCP server with copilot (if available)
    if command -v copilot &> /dev/null; then
        echo "[vibing.nvim] Registering MCP server with copilot..."
        if VIBING_RPC_PORT="${VIBING_RPC_PORT:-9876}" copilot mcp add vibing-nvim -- "$NODE_EXECUTABLE" "$MCP_SERVER_PATH" 2>/dev/null; then
            echo "[vibing.nvim] ✓ Registered vibing-nvim MCP server with copilot"
        else
            echo "[vibing.nvim] ⚠ Warning: copilot MCP registration failed"
            echo "[vibing.nvim] You can manually register by running: copilot mcp add vibing-nvim -- $NODE_EXECUTABLE $MCP_SERVER_PATH"
        fi
    fi
```

- [ ] **Step 2: `build.sh` の構文を検証する**

Run: `bash -n build.sh`

Expected: 出力なし（構文エラーなし）

- [ ] **Step 3: `docs/configuration.md` の adapter セクションを更新する**

`docs/configuration.md:96-101` のコードブロックを置き換える。

```lua
adapter = "claude",  -- Global backend adapter
                     -- "claude":  Claude CLI  (claude -p --output-format stream-json)
                     -- "codex":   Codex CLI   (codex exec --json)
                     -- "copilot": Copilot CLI (copilot -p --output-format json)
                     -- Overridable per-chat via the "agent" frontmatter field
```

- [ ] **Step 4: `doc/api-reference.md` を更新する**

27 行目を `adapter = "claude",  -- "claude" | "codex" | "copilot"` に、
416 行目を
`---@field adapter "claude"|"codex"|"copilot" バックエンドアダプター選択` に置き換える。

- [ ] **Step 5: `README.md` を更新する**

以下の 9 箇所を置き換える。左が現在の内容、右が置き換え後。

**(1)** 13 行目

```markdown
A powerful Neovim plugin that integrates **Claude**, **Codex**, and **GitHub Copilot** AI via CLI
backends, bringing intelligent, context-aware chat conversations directly into your editor.
```

**(2)** 46-48 行目の Multi-backend 項目

```markdown
- **🔀 Multi-backend** — Claude CLI (`claude -p --output-format stream-json`), Codex CLI
  (`codex exec --json`), or GitHub Copilot CLI (`copilot -p --output-format json`); switch
  globally via `adapter` or per-chat via the `agent` frontmatter field
```

**(3)** 79 行目の直後に 1 行追加

```markdown
- **GitHub Copilot CLI** (`copilot`) — `npm install -g @github/copilot`
```

**(4)** 229 行目

```lua
  adapter = "claude",              -- "claude" | "codex" | "copilot"
```

**(5)** 267 行目

```markdown
agent: claude # claude | codex | copilot (overrides global adapter setting for this chat)
```

**(6)** 321-322 行目の Mermaid サブグラフに 1 ノード追加

```text
        Codex["Codex CLI<br/>(codex exec --json)"]
        Copilot["Copilot CLI<br/>(copilot -p --output-format json)"]
```

**(7)** 326 行目の直後に 1 エッジ追加

```text
    Plugin -->|spawns & communicates<br/>JSON Lines| Copilot
```

**(8)** 341-344 行目（FAQ「Which AI backends are supported?」）

```markdown
- **Claude CLI** (`claude -p --output-format stream-json`) — full Claude Code capabilities
- **Codex CLI** (`codex exec --json`) — OpenAI Codex backend
- **GitHub Copilot CLI** (`copilot -p --output-format json`) — GitHub Copilot backend

Switch globally with `adapter = "claude"|"codex"|"copilot"` in setup, or per-chat by adding
`agent: claude`, `agent: codex`, or `agent: copilot` to a chat file's YAML frontmatter.

> **Note:** the Copilot backend does not yet support the in-chat Tool Approval UI. It runs with
> `--allow-all-tools` and honors the `permissions.deny` list via copilot's `--deny-tool` flag.
```

**(9)** 350 行目 / 358 行目 / 360 行目 / 380 行目

```markdown
themselves (`claude`, `codex`, `copilot`) are separate installs.
```

```markdown
- Additional Codex and GitHub Copilot backend options for non-Anthropic workflows
```

```markdown
Think of it as "Claude Code (or Codex, or Copilot) for Neovim users."
```

```markdown
- [GitHub Copilot CLI](https://github.com/github/copilot-cli)
```

- [ ] **Step 6: `README.ja.md` に同じ内容を日本語で反映する**

以下の 9 箇所を置き換える。

**(1)** 13-14 行目

```markdown
**Claude**・**Codex**・**GitHub Copilot** を CLI バックエンドとして統合し、コンテキストを理解した
AI チャットをエディタ内で直接利用できる Neovim プラグイン。
```

**(2)** 48-50 行目のマルチバックエンド項目

```markdown
- **🔀 マルチバックエンド** — Claude CLI(`claude -p --output-format stream-json`)、
  Codex CLI(`codex exec --json`)、GitHub Copilot CLI(`copilot -p --output-format json`)。
  `adapter` 設定でグローバルに、チャットごとには frontmatter の `agent` フィールドで切り替え
```

**(3)** 80 行目の直後に 1 行追加

```markdown
- **GitHub Copilot CLI**(`copilot`)— `npm install -g @github/copilot`
```

**(4)** 231 行目

```lua
  adapter = "claude",              -- "claude" | "codex" | "copilot"
```

**(5)** 270 行目

```markdown
agent: claude # claude | codex | copilot(このチャットに限りグローバルの adapter 設定を上書き)
```

**(6)** 324 行目の直後に 1 ノード追加

```text
        Copilot["Copilot CLI<br/>(copilot -p --output-format json)"]
```

**(7)** 329 行目の直後に 1 エッジ追加

```text
    Plugin -->|spawns & communicates<br/>JSON Lines| Copilot
```

**(8)** 344-347 行目（FAQ「どの AI バックエンドに対応していますか?」）

```markdown
- **Claude CLI**(`claude -p --output-format stream-json`)— Claude Code のフル機能
- **Codex CLI**(`codex exec --json`)— OpenAI Codex バックエンド
- **GitHub Copilot CLI**(`copilot -p --output-format json`)— GitHub Copilot バックエンド

setup の `adapter = "claude"|"codex"|"copilot"` でグローバルに、チャットファイルの frontmatter に
`agent: claude` / `agent: codex` / `agent: copilot` を書けばチャット単位で切り替えられます。

> **注意:** Copilot バックエンドはチャット内のツール承認 UI に未対応です。`--allow-all-tools` で
> 実行され、`permissions.deny` は copilot の `--deny-tool` フラグ経由で反映されます。
```

**(9)** 353 行目 / 361 行目 / 363 行目 / 382 行目

```markdown
(`claude`、`codex`、`copilot`)自体は別途インストールします。
```

```markdown
- Anthropic 以外のワークフロー向けに Codex / GitHub Copilot バックエンドも選択可能
```

```markdown
「Neovim ユーザーのための Claude Code(または Codex、Copilot)」と考えてください。
```

```markdown
- [GitHub Copilot CLI](https://github.com/github/copilot-cli)
```

- [ ] **Step 7: Markdown の lint と整形を実行する**

Run:

```bash
pnpm exec prettier --write README.md README.ja.md docs/configuration.md doc/api-reference.md
pnpm exec markdownlint README.md README.ja.md docs/configuration.md doc/api-reference.md
```

Expected: markdownlint がエラーなしで終了する

- [ ] **Step 8: 全テストと構文チェックを実行する**

Run: `pnpm run test:lua && pnpm run check`

Expected: すべて PASS

- [ ] **Step 9: コミット**

```bash
git add build.sh README.md README.ja.md docs/configuration.md doc/api-reference.md
git commit -m "docs(copilot): document the copilot backend and register its MCP server"
```

---

## 実装後の手動動作確認

自動テストではカバーできない部分（実際の copilot CLI との通信）を手動で確認する。E2E スイートに
入れないのは copilot の GitHub 認証が必要なため。

- [ ] `copilot --version` が 1.0.78 以上であることを確認する
- [ ] `require("vibing").setup({ adapter = "copilot" })` で Neovim を起動し `:VibingChat` を開く
- [ ] 「hello と返して」と送り、応答が**逐次**表示されること（一括表示でないこと）を確認する
- [ ] 続けて 2 通目を送り、1 通目の文脈が引き継がれていること（セッション再開）を確認する
- [ ] チャットファイルのフロントマターに `session_id` が書き込まれていることを確認する
- [ ] ファイルを読ませて `⏺ Bash(...)` のツール表示と結果が出ることを確認する
- [ ] 応答中に `:VibingCancel` を実行し、UI が固まらず即座に停止することを確認する
- [ ] `agent: copilot` を書いたチャットファイルで `agent`・`model` の補完が効くことを確認する
- [ ] `permissions_deny: [Bash]` を設定したチャットでシェル実行が拒否されることを確認する
- [ ] `mcp__vibing-nvim__nvim_list_windows` を copilot セッションから呼べることを確認する
- [ ] ツール表示で汎用フォールバックになっている `toolName` を記録し、`TOOL_LABELS`
      (`copilot_item_display.lua`) に追記する

## 後続 issue の作成

手動確認が完了したら、ツール承認 UI 対応の issue を作成する。本文には spec の
「スコープ外（後続 issue）」節の調査結果（`preToolUse` / `preMcpToolCall` / `permissionRequest`
は存在するが実行ごとの注入フラグが無いこと、`COPILOT_HOME` 案・`.github/hooks/` 案・
`--available-tools` 案の 3 つのトレードオフ）を転記する。
