# ADR 009: バックエンドを「記述子」にする — CLI 追加をリクエスト形式とレスポンス型の定義に縮める

## Status

Accepted — 実装済み（P0〜P6、本 ADR と同じ PR）。下の「移行計画」に各フェーズの着地点を記す。

## Date

2026-09-15

## Context

### 問い

現在のアダプタ層は `claude_cli.lua` / `codex_cli.lua` / `copilot_cli.lua` / `grok_cli.lua` と、
それぞれ専用の command builder・event processor・settings generator・tool vocabulary を持つ。
つまりバックエンドを 1 つ増やすたびに **コードを 1 系統書き足している**。

望んでいるのはそれではなく、

> リクエストの投げ方（argv の組み立て方）とレスポンスの型（ストリームの読み方）を定義すれば、
> どの CLI LLM でも接続できる設計。

であり、その際 **Claude バックエンドでの操作性、フックによる permission 管理などの現動作を「仕様」として
全バックエンドに保証する**こと。

この ADR は「それは可能か」を、いまのコードを 1 ファイルずつ読んで答えたものである。

### 結論を先に

**可能。ただし「投げ方＋型」の 2 つでは足りず、`hook`（permission ゲートの届け方）を含めた 3 つが
最小単位になる。** 3 つとも大半はデータ（テーブル）として記述でき、手続きが要る部分は有限個の
「戦略（strategy）」から名前で選ぶ形にできる。既存 4 バックエンドは、その戦略集合をすでに全部使い
切っている（settings ファイル / `-c` 上書き / `--plugin-dir` / プロジェクト内ディレクトリ）。
したがって **5 つ目の CLI が既存のどれかと同じ届け方を採っていれば、追加はテーブルとフィクスチャだけ**になる。

何が可能で何が不可能かの根拠は以下。

### いま何が共有され、何が重複しているか（実測）

`lua/vibing/infrastructure/adapter/` と `hooks/` を行数で切ると:

| 区分                                                    | 行数  |
| ------------------------------------------------------- | ----- |
| claude 固有（adapter, builder, event processor, hooks） | 1,536 |
| codex 固有（同上 + permission_profile, plugin_config）  | 2,262 |
| copilot 固有                                            | 860   |
| grok 固有                                               | 1,044 |
| 共有（cli_runtime, stream_handler, common builder 等）  | 1,285 |

固有側 5,700 行のうち、**バックエンドの事実（フラグ名・イベント名・ツール名）を書いている行**は
1/4 程度で、残りは「その事実をどう処理するか」の手続きが 4 回書かれている。具体的には:

- **`stream()` は 4 本ともほぼ同一。** 各 200〜270 行のうち、差分は (a) どの settings generator を
  builder の前に走らせるか、(b) builder の第 5 引数に何を渡すか、(c) 子プロセスの環境変数、
  (d) `chat_bufnr` を登録するか、(e) `_tool_vocabulary` を渡すか、(f) stderr のフィルタ、
  (g) `stdin = ""` の有無 —— の 7 点だけ。残りの handle_id 発番、timeout タイマー、
  `ActiveStreamRegistry` 登録、`perm_handler.set_active_opts`、`wrapped_on_done`、
  `RateLimitDetector.attach`、`CliRuntime.spawn` は同じ順序で同じことをしている。
  `handbook/architecture/module-map.md` は「差分が共有行より多いので per-adapter に残した」と
  書いているが、上の 7 点はいずれも **記述子の 1 フィールドで表せる**ものであり、その判断は
  記述子という抽象が無かった時点のものである。
- **event processor は「デコード」と「描画」を混ぜている。** `codex_item_display.lua` が
  `FileChange(2 files)` と描き、`cli_event_processor.lua` が `Edit(path)` と描く。ツール結果の
  切り詰め (`ToolDisplay.format_result_text`) は共有だが、ヘッダ行の形式、reasoning の `💭`、
  subagent の扱いは各 processor が独自に持つ。**描画の差はバックエンドの事実ではなく、共有されて
  いなかった結果**である。
- **command builder は共通化が半分進んでいる。** `command_builder_common.lua`（言語・context
  prefix・binary 解決）、`non_claude_model.lua`、`reasoning_effort.lua` は #515/#537 で抜き出された。
  残りの各 builder は「フラグ名」「permission_mode → ネイティブ設定」「lightweight の閉じ方」
  「system prompt をどこに載せるか」の 4 種類の事実を手続きで書いている。
- **permission ゲートは既に共有インフラで、差分は入口だけ。** `rpc/handlers/permission.lua`・
  `can_use_tool.lua`・`bin/hooks/pre-tool-use.sh` はバックエンドを知らない（#516）。差分は
  「フックをその CLI にどう登録するか」（4 種類の settings generator）、「ペイロードのキー名と
  ツール名」（vocabulary、すでにテーブル）、「deny の合図の仕方」（shell 内の `claude|copilot` 分岐）
  の 3 点に閉じている。

### バックエンド名が固有モジュールの外へ漏れている箇所（全数）

`lua/vibing/` で `codex|grok|copilot` を含む行は 159 行あり、`adapter/`・`hooks/`・
`core/constants/agents.lua` を除くと以下に集約される。これは「共有コードはバックエンド名を持たない」
という `.claude/rules/architecture.md` の不変条件からの逸脱であり、記述子化の際に閉じる対象:

| 場所                                                                       | 内容                                                               | 記述子化後の姿                                                           |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `core/utils/token_usage.lua`（`backend == "codex"` 分岐 ×5）               | 累積カウンタ→差分計算、フッタの `codex-input=` 形式                | `usage.scope = "cumulative" \| "per_request"` を記述子が宣言             |
| `application/chat/send_message.lua:518-567`                                | `read_last_codex_totals`                                           | 同上。scope が cumulative なら前回フッタから差分を取る（名前を持たない） |
| `config.lua:541-547`（`permissions.codex_*`, `grok.executable`）           | バックエンド固有設定がトップレベル・`permissions` 直下             | `backends.<id>.*` に統一（旧キーは移行して警告）                         |
| `init.lua:30, 576-591`                                                     | codex profile の bootstrap、`:VibingReloadCommands` の cache clear | 記述子の `on_project_open` / `clear_caches` フック                       |
| `presentation/chat/modules/file_manager.lua:22`                            | codex profile の生成                                               | 同上                                                                     |
| `application/chat/auto_compact.lua`, `cache_expiry.lua`, `auto_resume.lua` | コメントと `agent_id` 分岐                                         | `features.auto_compact = "native" \| "turn"` 等を記述子が宣言            |
| `infrastructure/permissions/matchers.lua`                                  | `mcp__` の `-`/`_` 畳み込み（コメントで codex に言及）             | 事実そのものは共有で正しい。コメントのみ                                 |
| `core/constants/modes.lua`                                                 | コメントのみ                                                       | —                                                                        |

`grok_cli.lua` が `on_chunk(chunk)` を `handle_id` 無しで呼んでいる（他 3 つは
`on_chunk(chunk, handle_id)`）のもこの種の逸脱で、`stream()` が 1 本になれば構造的に消える。

### Claude の現動作を「仕様」として書き下す

「Claude での動作が正」を実装可能な契約にすると、次の 14 項目になる。**記述子の各フィールドはこの
どれかを満たすために存在する。** ただしこれは**契約の一覧であって、テストの一覧ではない** — 記述子
ループで覆えるのは一部であり、どの契約がどこで検証される（あるいはされない）かは後述の §6 にある。

| #   | 契約                                                                                                                                                      | いま Claude で実現している場所                                       |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| C1  | テキストは差分（delta）で逐次表示される                                                                                                                   | `cli_event_processor` `stream_event.text_delta`                      |
| C2  | ツール呼び出しは `⏺ Name(summary)` ＋ `⎿ result` で描かれ、`on_tool_use` が canonical 名と `file_path`/`command` で呼ばれる                               | 同 `assistant`/`user` イベント、`tool_display.lua`                   |
| C3  | session_id はストリームから拾い、次ターンで `--resume` 相当に渡す。fork/subagent の区別がある                                                             | `session_manager`, `--resume`/`--fork-session`                       |
| C4  | 最初の応答が 120 s 来なければ壊れた session として殺し、リセットする                                                                                      | `INITIAL_RESPONSE_TIMEOUT_MS` タイマー                               |
| C5  | 全ツール呼び出しが PreToolUse で Neovim に届く。**fail-closed**（接続不能・応答なしは deny）                                                              | `pre-tool-use.sh`, `settings_generator`                              |
| C6  | 決定は `deny` / `allow` / `defer` の 3 値。deny の理由はモデルに届く。`allow` は vibing-nvim の MCP ツールのみ                                            | `permission.lua` `write_hook_response`, shell                        |
| C7  | `ask` は CLI を殺してから承認 UI を出し、答えは `## User` に書かれて次ターンで再送される                                                                  | `cancel_and_deny` → `on_approval_required`                           |
| C8  | ツール実行の直前に git ツリーのベースラインを取る（差分・patch・`gd`）                                                                                    | `permission.lua` `_capture_baselines`                                |
| C9  | granular rule（`paths`/`commands`/`patterns`/`domains`）が canonical ツール名と `file_path` で評価される                                                  | `can_use_tool.lua`, `matchers.lua`, vocabulary の 3 正規化           |
| C10 | permission_mode 6 種のうち CLI 側に意味があるものはネイティブ機構に写像され、無いものは安全側に倒す                                                       | `--permission-mode`（codex は sandbox、grok は `auto→default`）      |
| C11 | lightweight 呼び出しは「ツール無し・プロジェクト設定無し・ユーザー MCP 無し・フック無し・utility_model」を **CLI 側スキーマ変更で黙って外れない形で**守る | `core/types.lua` の義務、各 builder                                  |
| C12 | usage limit は 3 チャネル（stream event / StopFailure hook / error text）のあるものを合成し、`_rate_limit_info` にする                                    | `rate_limit_detector.lua`（既に共有）                                |
| C13 | トークン使用量が `### Tokens` フッタに出る                                                                                                                | `token_usage.lua`                                                    |
| C14 | `effort`・`language`・`env`・orchestration 指示・`.vibing/system-prompt.md` が届く                                                                        | `cli_command_builder` の system prompt ブロック、`agent_environment` |

**C7 は #778（PR #786）で部分的に superseded である。** `measured_wait_floor_sec` を持つバックエンド
では CLI を殺さず、PreToolUse フックの中で `.res` を書かずに待ち、同じターンの中で答える。持たない
バックエンドは C7 の記述のままである。詳細は `handbook/architecture/approval-without-kill.md`。上の行
自体は決定時点の記録として残してある。

このうち **C5〜C9 は共有インフラが担っており、バックエンドが供給するのは入口（フック登録・ペイロード
正規化・決定の合図）だけ**である。C1〜C4・C12・C13 はストリームの型、C10・C11・C14 はリクエストの
投げ方に属する。つまりユーザーの言う「投げ方」と「型」に、「フックの届け方」を足せば契約は閉じる。

## Decision（提案）

### 1. バックエンドは Lua テーブルの「記述子」1 ファイルになる

`core/constants/agents.lua` を拡張し、1 バックエンド = `infrastructure/adapter/backends/<id>.lua` の
記述子 1 ファイルとする。`agents.lua` は「何も require しない」不変条件を保つため、補完 UI に要る
`id / description / models` だけを残し、記述子本体は遅延 require する。

```lua
--- infrastructure/adapter/backends/claude.lua  （参照実装。契約 C1〜C14 の基準）
return {
  id = "claude",
  binary = { name = "claude", missing = "Claude CLI not found in PATH. Please install Claude Code CLI." },

  -- ── リクエストの投げ方 ────────────────────────────────────────────────
  request = {
    base = { "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages" },
    model = { flag = "--model", names = "claude" },       -- "claude": 短縮名をそのまま渡す
    effort = { flag = "--effort" },
    resume = { flag = "--resume", fork = "--fork-session" },
    prompt = { position = "tail", terminator = "--" },     -- `-- <prompt>` を末尾に
    system_prompt = { channel = "flag", flag = "--append-system-prompt" },
    permission_mode = { flag = "--permission-mode" },      -- 6 値すべて素通し
    tool_lists = { allow = "--allowedTools", deny = "--disallowedTools", separator = "," },
    settings_sources = { flag = "--setting-sources" },
    plugins = { channel = "plugin_dir", flag = "--plugin-dir" },
    lightweight = { strategy = "remove_tools", args = { "--tools", "", "--setting-sources", "",
                    "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}' } },
    -- 記述子で表せない事実の逃げ道。claude では subagent 転送と user_servers の再登録。
    extra_args = "vibing.infrastructure.adapter.backends.claude_extra",
  },

  -- ── 子プロセスの環境 ──────────────────────────────────────────────────
  env = {
    unset = { "CLAUDECODE" },
    apply = "vibing.infrastructure.adapter.backends.claude_env",  -- git_instructions の三値
    lightweight = nil,
  },

  -- ── レスポンスの型 ────────────────────────────────────────────────────
  response = {
    framing = "jsonl",
    decoder = "vibing.infrastructure.adapter.decoders.claude_stream_json",
    stdin = nil,                                            -- codex/copilot/grok は ""
    stderr_filter = nil,
    usage = { scope = "per_request" },
    rate_limit_channels = { "stream_event", "stop_failure_hook", "error_text" },
  },

  -- ── フック（permission ゲートの届け方）────────────────────────────────
  hook = {
    transport = "settings_file",          -- {"settings_file","config_override","plugin_dir","project_dir"}
    dialect = "claude",                    -- {"claude","copilot_flat", ...}
    payload = "claude",                    -- tool_name/tool_input（vocabulary.normalize_payload 不要）
    timeout_sec = 120,
    keep_in_bypass = true,                 -- ベースライン採取のため bypass でも登録する（C8）
    stop_failure = true,
  },
  vocabulary = nil,                        -- Claude 名が canonical なので不要

  -- ── UI / 機能 ─────────────────────────────────────────────────────────
  features = { chat_bufnr = true, ask_user_question = true, subagent_text = true },
  clear_caches = {},
}
```

同じ形で書いた codex は次のようになる（現在の `codex_command_builder` / `codex_cli` から機械的に
写したもので、事実は一切変えていない）:

```lua
return {
  id = "codex",
  binary = { name = "codex", missing = "Codex CLI not found in PATH. Please install codex-cli." },
  request = {
    base = { "exec", "--json" },
    resume = { subcommand = { "resume" } },                  -- `codex exec resume <id> --json`
    model = { flag = "-m", names = "native" },               -- Claude 短縮名は落とす（non_claude_model）
    effort = { config = 'model_reasoning_effort="%s"' },     -- `-c key=value` 系
    prompt = { position = "tail" },
    system_prompt = { channel = "prompt_prefix" },           -- developer_instructions は plugin 用に予約
    permission_mode = { map = {
      bypassPermissions = { "--dangerously-bypass-approvals-and-sandbox" },
      plan = { fresh = { "-s", "read-only" }, resume = { "-c", 'sandbox_mode="read-only"' } },
      ["*"] = "vibing.infrastructure.adapter.backends.codex_permission_profile",  -- 既存モジュール
    } },
    plugins = { channel = "config_override", module = "…codex_plugin_config" },
    lightweight = { strategy = "sandbox", args = { "--ignore-user-config", "--strict-config",
      "-c", 'sandbox_mode="read-only"', "-c", "tools.web_search=false",
      "-c", 'approval_policy="never"', "-c", "project_doc_max_bytes=0" } },
    extra_args = "…codex_extra",                              -- auto_compact の `-c`
  },
  response = {
    framing = "jsonl",
    decoder = "…decoders.codex_exec_json",
    stdin = "",
    stderr_filter = { drop = { "Reading additional input from stdin%.%.%.%s*" } },
    usage = { scope = "cumulative" },
    rate_limit_channels = { "error_text" },
  },
  hook = {
    transport = "config_override",         -- `-c hooks.PreToolUse=[…]` + `--dangerously-bypass-hook-trust`
    stage_script_in_cwd = true,            -- 書き込み可能ルート内に置かないと hang
    dialect = "claude", payload = "claude",
    timeout_sec = 300, keep_in_bypass = true,
  },
  vocabulary = "…codex_tool_vocabulary",   -- 既存テーブル
  features = { chat_bufnr = false, ask_user_question = false },
  on_project_open = "…project_codex_permissions",
  clear_caches = { "…codex_plugin_config", "…codex_permission_profile" },
}
```

### 2. `stream()` は 1 本になる

`claude_cli.lua` 他 3 ファイルは消え、`infrastructure/adapter/cli_adapter.lua` が記述子を受け取って
今日の `stream()` を 1 度だけ実装する。差分 7 点はすべて記述子のフィールドから決まる:

| 今日の差分                           | 記述子のフィールド                              |
| ------------------------------------ | ----------------------------------------------- |
| どの settings generator を走らせるか | `hook.transport`（戦略 4 種から選ぶ）           |
| builder の第 5 引数                  | 戦略が返す argv 断片を `request` エンジンへ渡す |
| 子プロセス環境                       | `env.unset` / `env.apply` / `env.lightweight`   |
| `chat_bufnr` 登録                    | `features.chat_bufnr`                           |
| `_tool_vocabulary`                   | `vocabulary`                                    |
| stderr フィルタ                      | `response.stderr_filter`                        |
| `stdin = ""`                         | `response.stdin`                                |

`factory.create(agent_type)` は `CliAdapter.new(descriptor, config)` になり、`adapter.name` は
`descriptor.id` から導く（`factory.agent_id` の逆引きが不要になる）。

### 3. レスポンスの型は「canonical イベント集合」への写像で定義する

いちばん重要な設計判断。**記述子の `response.decoder` は描画をしない。** 生の JSON 行を次の
canonical イベントに翻訳するだけで、描画・`on_tool_use`・subagent カウント・session 保存は共有の
`event_renderer.lua` が 1 度だけ実装する:

```lua
---@alias Vibing.CanonicalEvent
---| { kind = "session",      session_id: string }
---| { kind = "first_response" }                                   -- C4 のタイマー解除
---| { kind = "text",         delta: string }                      -- C1
---| { kind = "thinking",     delta: string }                      -- grok の thought / codex の reasoning
---| { kind = "tool_start",   id: string, name: string, input: table }        -- C2（canonical 名）
---| { kind = "tool_end",     id: string, result: string, is_error: boolean } -- C2
---| { kind = "subagent_text", parent_id: string, text: string }   -- Claude の --forward-subagent-text
---| { kind = "usage",        usage: table }                       -- C13。scope は記述子から
---| { kind = "rate_limit",   info: Vibing.RateLimitInfo }         -- C12
---| { kind = "cli_info",     version?: string, compacted?: boolean }
---| { kind = "turn_failed",  message: string }                    -- result.is_error / turn.failed
```

デコーダは `decode(msg, state) -> Vibing.CanonicalEvent[]`。1 行を canonical イベント列に写す
以外のことをせず、**描画も判断も持たない**。ターンをまたぐ状態（Claude の `tool_use_map` と
`input_json_delta` の連結、grok の thought/text モード）は呼び出し側が所有する `state`
テーブルに閉じ、**デコーダはそれを直接更新する**。次状態を戻り値で返す形にはしない
（後述の「着地点」P1 を参照）。
grok・copilot のデコーダは今日の event processor から描画を抜いただけの 40〜60 行、codex は
`item.*` を `tool_start`/`tool_end` に写すだけになる。Claude の subagent 周り
（`parent_tool_use_id` を **必ず helper 経由で判定する**という `.claude/rules/features.md` の
不変条件を含む）はデコーダ内に残る。これは Claude というバックエンドの事実であり、共有側は
`subagent_text` を受け取るだけでよい。

これで **描画の不一致（codex の `FileChange(2 files)` と claude の `Edit(path)`）が構造的に消える**。
`tool_start.input` は vocabulary の `normalize_input` を通ってから renderer に渡るので、
`on_tool_use(name, input.file_path, input.command)` も 1 箇所で済み、`send_message.lua` の
`FileChange` 特別扱い（カンマ区切りパス）が不要になる。

**宣言的 JSON パス（`text = "$.event.delta.text"` のような）にはしない。** grok と copilot は
それで書けるが、Claude の `content_block_start`→`input_json_delta`→`assistant` の 3 段合成と
`parent_tool_use_id` の `vim.NIL` 罠は式では書けず、2 系統の記述方法を持つほうが悪い。
「デコーダは 1 モジュールだが、描画も判断も持たない」が線。

### 4. リクエストの投げ方は「フラグ表 ＋ 逃げ道」で定義する

`command_builder_common.lua` を `request_builder.lua` に育て、記述子の `request` を読んで argv を
組む。順序は今日の Claude builder に固定（binary → base → model → effort → resume → lightweight
or permission → plugins → system prompt → settings sources → prompt）。各フィールドは
`{ flag = }`（`--x value`）、`{ config = }`（`-c key=value`）、`{ subcommand = }`、`{ map = }` の
いずれかで、**値の解決（`utility_model` 優先、`effort=default` は渡さない、Claude 短縮名の扱い）は
共有側**が行う —— #537 の「3 つ直し忘れた」が起きない形にするのが目的なので、ここは記述子側に
書かせない。

`extra_args(opts, config, session_id) -> string[]` の逃げ道は残す。codex の permission profile
（689 行の TOML コンパイラ）と plugin config、claude の `cli_mcp_config` はここに入る。
**逃げ道を使う項目は記述子に名前が出るので、「この CLI は何を手続きで書いているか」が一覧できる。**
それが無い今日は、`codex_command_builder.lua` を読み切らないと分からない。

### 5. フックは「transport × dialect」の 2 軸で選ぶ

`hooks/` の 4 generator は、記述子が選ぶ 4 つの transport 戦略になる:

| transport         | いま使うバックエンド | 手続きとして残るもの                                                         |
| ----------------- | -------------------- | ---------------------------------------------------------------------------- |
| `settings_file`   | claude               | `.vibing/hook-settings.json` を書いて `--settings` で渡す                    |
| `config_override` | codex                | script を cwd 内に原子的に stage し、`-c hooks.PreToolUse=…` ＋ trust bypass |
| `plugin_dir`      | copilot              | 使い捨て plugin manifest を書いて `--plugin-dir`                             |
| `project_dir`     | grok                 | `<cwd>/.grok/hooks/` に書き、trusted_folders に追記、非 git を警告           |

`dialect` は `pre-tool-use.sh` の第 1 引数（決定の合図の仕方）で、いま `claude` と `copilot`。
shell に残す判断は `handbook/architecture/cli-integration.md` の通り（fail-closed の 90 行を
2 つ持たない）。記述子化で変わるのは「**誰が引数を決めるか**」だけ —— generator 内の固定文字列から
`hook.dialect` へ移り、新しい方言が要るときは shell の `case` に 1 節足す。

ペイロード側（`tool_name`/`tool_input` か `toolName`/`toolArgs` か）は `vocabulary.normalize_payload`
のままで、これは既にテーブルである。

**`hook.transport` が既存 4 種のどれにも当たらない CLI が来たときだけ、戦略モジュールを 1 つ書く。**
それがこの設計の「コードを書く」唯一のケースであり、書くのは `ensure(cwd) -> argv|path` の 1 関数と
そのスペックである。

### 6. 適合性テスト（conformance suite）が「Claude が正」を機械的に保証する

`tests/lua/infrastructure/adapter/conformance/` に、**記述子を全部ループして同じアサーションを
かけるスペック**を置く。今日すでに `tests/helpers/adapter_stream.lua` の `adapters()` と
`stream_options_spec.lua`、`binary_cache_spec.lua`、`cli_runtime_spec.lua` がこの形をしており、
それを契約のうち **バックエンドごとに答えが変わりうる項目** に広げる:

| スペック                        | 入力                                                     | アサーション                                                                                           |
| ------------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `decoder_spec`                  | `tests/fixtures/streams/<id>/*.jsonl`（実 CLI から採取） | canonical イベント列が期待通り。text/tool_start/tool_end/session/usage が揃う                          |
| `renderer_spec`                 | canonical イベント列（バックエンド非依存）               | 描画文字列と `on_tool_use` 引数が **全バックエンドで同一**                                             |
| `hook_payload_spec`             | `tests/fixtures/hooks/<id>/*.json`（実 CLI から採取）    | `normalize_payload → to_canonical → normalize_input` 後に `tool_name` が canonical、`file_path` が立つ |
| `hook_registration_spec`        | 記述子                                                   | transport が返す argv/ファイルにスクリプトの絶対パスが含まれ、timeout が `MAX_WAIT` を上回る           |
| `stream_options_spec`（既存）   | stub した `vim.system`                                   | text/cwd/env の `VIBING_*`、registry 登録、permission opts、タイマー                                   |
| `lightweight_spec`              | `opts.lightweight = true` の argv                        | 記述子の `lightweight.args` が全部含まれ、hook と plugin の argv が **含まれない**                     |
| `rate_limit_spec`（既存の拡張） | 非 0 終了 + limit 文言                                   | `_rate_limit_info` が返る                                                                              |
| `permission_mode_spec`          | 6 モード × 記述子                                        | 各モードが argv に写るか、写らないなら安全側の値に倒れている                                           |

新バックエンドは **記述子 1 ファイル ＋ 実 CLI から採取した fixture** を置いた時点でこの全部に
掛かる。落ちたところが「その CLI で Claude の契約のどこが満たせないか」の一覧になる。

**この表が見るのは C5〜C9 の「入口」だけである。** 上の契約表で述べたとおり C5〜C9 の本体は
共有インフラであり、記述子をループしても同じコードを何度も通るだけなので、ここでは
バックエンドが供給する部分——フックの登録（C5）、ペイロードの正規化（C9）、決定の方言（C6）
——に絞る。本体を担うのは共有スペックの側である:

| 契約 | 本体を担うスペック                                                                                              |
| ---- | --------------------------------------------------------------------------------------------------------------- |
| C5   | `hooks/*_settings_generator_spec.lua`（登録の形と、`timeoutSec` が `MAX_WAIT` を上回ること）                    |
| C6   | `rpc/handlers/permission_decision_spec.lua`（deny / allow / defer の 3 値）                                     |
| C8   | `core/utils/git_snapshot_spec.lua`                                                                              |
| C9   | `permissions/can_use_tool_spec.lua`、`permission_rules_spec.lua`、`rpc/handlers/permission_vocabulary_spec.lua` |

**C7（`ask` → CLI を殺す → 承認 UI → 次ターンで再送）だけは記述子ループでは覆えていない。**
その経路は生きたストリームを必要とし、単体スペックはアクティブなストリームを持たない状態を
前提に書かれているため、実際に確かめているのは E2E（`tests/e2e/ask_user_question_spec.lua`、
`nvim_ask_user_question_spec.lua`）である。新バックエンドを足したとき、ここだけは
conformance が緑でも未検証のまま残る。

`handbook/architecture/cli-integration.md` の「全部実 CLI から採ったものであり、ドキュメントから
読んだものではない」という方針は fixture に引き継ぐ。**fixture ディレクトリの README に CLI の
バージョンを書く**（今日はコメントに散っている `codex 0.153.4` / `copilot 1.0.78` / `grok 0.2.101`）。

## 記述子で表せないもの（正直な限界）

「投げ方と型を書けば済む」に **ならない**ものを挙げておく。いずれも CLI 側の測定でしか分からない
事実であり、記述子はそれを「どの戦略を選ぶか」「どのフラグを足すか」として **記録はできる**が、
発見はできない。

1. **フック登録の罠。** codex は untrusted なフックで hang し（`--dangerously-bypass-hook-trust`
   必須）、書き込み可能ルート外のスクリプトでも hang する。copilot はフックの timeout が
   **fail-open**、matcher を書くと regex として拒否される。grok は git リポジトリ外では
   `.grok/hooks/` を読まない。これらは戦略モジュールの中に住み続ける。
2. **lightweight の閉じ方。** claude は `--tools ""` で消せる、codex は消せないので sandbox で
   囲う、copilot は存在しないツール名を allowlist に渡す、grok は空文字だと fail-open するので
   実在する無害ツール名を渡す。`lightweight.strategy` の 4 値はこの 4 つの事実そのものであり、
   5 つ目の CLI がどれに当たるかは測るしかない。`--strict-config` のような「黙って外れない保険」も
   同様。
3. **permission_mode の写像。** Claude の 6 モードに 1:1 対応する CLI は無い。codex は sandbox
   3 段階＋TOML プロファイル、grok は `auto` が無い、copilot は `--allow-all-tools` 前提で
   ゲートはフック側。`permission_mode.map` はこれを書き留める場所であって、正しさは実測に依る。
4. **決定の方言。** `claude` と `copilot_flat` の 2 つに、Gemini CLI を入れると 3 つ目
   （トップレベル `{"decision":"deny","reason":…}`）が要る（後述）。shell の `case` は増える。
5. **MCP / plugin の運び方。** `--plugin-dir` があるのは claude と copilot だけ。codex は `-c`
   に展開し、grok には運ぶ手段が無い。`plugins.channel` で選ぶが、`config_override` の展開器
   （`codex_plugin_config`, 226 行）は codex 固有のまま。
6. **AskUserQuestion の経路。** vibing-nvim の MCP サーバーに届く CLI（claude、条件付きで
   codex）だけが使える。`features.ask_user_question` は宣言であって実装ではない。
7. **transport が前提にする信頼境界。** 4 つの transport はいずれもフックの登録物
   （`.vibing/hook-settings.json`、`.vibing/codex-pre-tool-use.sh`、`.vibing/copilot-plugin/`、
   `.grok/hooks/`）を**作業ディレクトリの中**に置く。`codex-pre-tool-use.sh` は
   `--dangerously-bypass-hook-trust` 付きで実行されるので、CLI 自身の trust チェックはこれらを
   守ってくれない。ステージングは pid 付きの一時名 → `setfperm` → `rename(2)` で行うが、それが
   防ぐのは**途中まで書けたスクリプトが読まれること**であって、書き込み権限を持つ別のプロセスが
   最終パスを差し替えることではない。つまりこの設計は **「作業ディレクトリに書ける者は信頼
   できる」を境界として敷いている**。その者はプロジェクトのソース自体を書き換えられ、それは
   どの CLI もそのまま読んで実行しうるのだから、フックを守っても境界は動かない——という判断で
   あって、検証を省いた結果ではない。共有された書き込み可能ディレクトリでチャットを開くことは、
   この前提の外側にある。

したがって正確な言い方は: **「既存 4 CLI のどれかと同じ transport / 決定の方言 / lightweight
戦略 / prompt channel を持ち、デコーダが既存のどれかと同型の CLI なら、追加はテーブルと fixture
だけ。どれか 1 つでも新しいものを持ち込む CLI は、その 1 モジュールを書く」**。今日は後者の
ケースでも 1 系統（5〜6 ファイル、1,000〜2,000 行）を書いている。

## Worked example: Gemini CLI を記述子で書くと

5 つ目の候補として、設計が閉じるかを Gemini CLI で当てた。**ここに書く事実はドキュメント
（`google-gemini/gemini-cli` の `docs/cli/headless.md`, `docs/hooks/reference.md`）から読んだものであり、
このリポジトリの方針上、実装前に実 CLI で採り直す必要がある。**

| 契約        | Gemini CLI の対応物（未検証）                                                                                                                                                                                                                                  | 記述子での表現                                                                                                                                                                                                  |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 投げ方      | `gemini -p <prompt> --output-format stream-json --model <m>`、`--resume <id>`（stdin/位置引数と併用不可の報告あり）                                                                                                                                            | `request.base`, `model.flag`, `resume.flag`, `prompt.position = "flag"`                                                                                                                                         |
| 型          | JSONL: `init`（session_id, model）/ `message` / `tool_use` / `tool_result` / `error` / `result`（usage）                                                                                                                                                       | `decoders.gemini_stream_json` — copilot と同程度の大きさ                                                                                                                                                        |
| フック      | `BeforeTool`。stdin は `tool_name` / `tool_input` / `session_id` / `cwd`（**Claude 互換**）。決定は stdout に `{"decision":"allow"\|"deny","reason":…}`、exit 2 + stderr でも deny。登録は `settings.json` の `hooks` のみで、**per-run のフラグは文書に無い** | `hook.transport = "project_dir"`（`.gemini/settings.json`。grok と同型で、プロジェクト設定を読む条件と trust の有無を測る必要がある）, `hook.payload = "claude"`, `hook.dialect = "gemini"`（**3 つ目の方言**） |
| 語彙        | `read_file` / `write_file` / `replace` / `run_shell_command` / `glob` / `grep_search` / `web_fetch`（既定ツール名）                                                                                                                                            | `vocabulary` テーブル 1 つ。`normalize_payload` 不要                                                                                                                                                            |
| lightweight | 文書に `--tools` 相当が見当たらない → `sandbox` 戦略か、`--approval-mode` ＋ deny 群になる                                                                                                                                                                     | **測るまで決められない**（限界 2 に該当）                                                                                                                                                                       |
| usage       | `result` に per-model の usage。ターン毎か累積かは要確認                                                                                                                                                                                                       | `usage.scope`                                                                                                                                                                                                   |

得られる見立て: **Gemini は「戦略を新規に書かなくてよい」側**（transport は grok と同型、payload は
Claude 互換）で、必要な追加コードはデコーダ 1 本、方言 1 節、テーブル群、fixture。`defer` が
Gemini の自前ゲートにどう解釈されるか（`decision` を返さず exit 0 したとき）は C6 の要であり、
最初に測る項目になる。

## 移行計画

各フェーズは単独でマージでき、既存テストが全部通る状態を保つ。**フェーズ 0 で挙動を一切変えずに
形だけ 1 本化し、以降で中身を記述子へ移す。**

| フェーズ | 内容                                                                                                                                                                                                                                                                                           | 触るもの                                                                           | 挙動変更                                                       |
| -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| P0       | `cli_adapter.lua` を作り、4 つの `stream()` を 1 本に。記述子は当面「今日のモジュールへの関数参照」（`build = CodexCommandBuilder.build` 等）を持つだけ                                                                                                                                        | 4 adapter ファイル削除、`factory`, `agents.lua`, `adapter_stream.lua`              | 無し（grok の `on_chunk` 引数のみ揃う）                        |
| P1       | canonical イベント集合と `event_renderer.lua`。4 つの event processor をデコーダに縮め、`*_item_display.lua` を廃止                                                                                                                                                                            | `cli_event_processor` 他 3 つ、`tool_display`, `send_message` の `FileChange` 分岐 | ツール描画が全バックエンドで Claude 形式に揃う（意図した変更） |
| P2       | `request_builder.lua`。フラグ表で書ける部分を記述子へ、書けない部分を `extra_args` へ                                                                                                                                                                                                          | 4 つの command builder、`command_builder_common`                                   | 無し（argv のスナップショットテストで担保）                    |
| P3       | フック transport を戦略 4 種に整理し、`hook.dialect` を記述子から渡す                                                                                                                                                                                                                          | `hooks/*_settings_generator.lua`, `pre-tool-use.sh` の引数の出所                   | 無し                                                           |
| P4       | 漏れの回収: `usage.scope`、`backends.<id>.*` 設定、`clear_caches`、`on_project_open`                                                                                                                                                                                                           | `token_usage`, `send_message`, `config.lua`, `init.lua`, `file_manager`            | 設定キーの移行（旧キーは警告付きで読む）                       |
| P5       | conformance suite を C1〜C14 全項目に拡張、fixture を `tests/fixtures/{streams,hooks}/<id>/` に集約し CLI バージョンを記録                                                                                                                                                                     | `tests/`                                                                           | —                                                              |
| P6       | 文書。`handbook/ADAPTER_DEVELOPMENT.md` は **現状と一致していない**（`vibing.adapters.base` を require し、`init.lua` に分岐を足す手順、curl で HTTP を叩く例）。記述子の書き方と「測るべき項目チェックリスト」に書き換える。`module-map.md` の「`stream()` は per-adapter」の段落を差し替える | `handbook/`, `.claude/rules/architecture.md` の Backend Seams                      | —                                                              |

P0 と P1 が効果の大半で、それだけで固有側 5,700 行のうち `stream()` 4 本（約 950 行）と
item_display 2 本・event processor の描画部（約 400 行）が消える。P2 は削減量より
「#537 型の直し忘れが構造的に起きない」ことが目的。

### 着地点（実装後の差分）

計画どおりに進めたうえで、実装時に判断が変わった点だけを記す。

- **P0**: `*_cli.lua` は削除せず 2 行のシムとして残した。require パス・export 名・`adapter.name`
  を外部（テスト、`doc/api-reference.md`、ユーザーの `get_adapter()`）が握っているため。
- **P1**: canonical イベントは計画の 11 種そのまま。デコーダはツール名を **CLI の語彙のまま**
  出し、renderer が `vocabulary` で正規化する形にした（permission ハンドラと同じ表を通すため）。
  `send_message` の `FileChange` 分岐は消えた。
  **デコーダは「純関数」にならなかった**。当初の計画はそう書いていたが、4 本すべてが渡された
  `state` を直接更新する（claude は `state.session_id`、codex は `state.started` によるツールの
  開始・終了の対応付け、copilot は `toolCallId` を送ってこない呼び出しに振る匿名 id）。
  `decode` が次状態を返す形にすれば署名としては純粋になるが、呼び出し側は結局それを
  同じ 1 つのイベントコンテキストに書き戻すだけで、「戻り値を書き戻し忘れる」という
  新しい失敗の仕方が増える。**保証したかったのは無副作用ではなく「描画も判断も持たない」**
  ことなので、契約はそちらに寄せた。
- **P2**: フラグ表で表せない部分は `extra` として **既存の `<id>_command_builder.lua` に残し**、
  記述子の `request.parts` から名前で参照する。builder モジュールの `build()` は記述子の spec を
  通すシムになり、既存の builder スペック約 175 件がそのまま argv のスナップショットになった。
- **P3**: generator 4 本はファイルを動かさず `hooks/transports.lua` の 4 エントリとして名前を
  付けた。方言は各 generator の引数になり、claude は「引数なし」なので既存の settings ファイルは
  バイト単位で同じ。
- **P4**: 設定キーは `backends.<id>.*` に移し、旧キー（`permissions.codex_*`、
  `agent.codex_provider_notice.enabled`、`grok.executable`）は警告付きで読み替える。項目の宣言は
  `agents.lua` の `config_fields`（純データ）で、`config.lua` はそこから既定値と検証を導く。
  Tokens フッタのマーカーは `total-*` で書き、旧 `codex-*` も読む。
- **P5**: conformance suite は `descriptor_shape` / `request` / `hook_payload` /
  `hook_registration` / `renderer_parity` / `stream_fixtures` の 6 本。`request` が codex の
  lightweight で hook 断片を落としていない穴を 1 つ見つけ、塞いだ。
  実 CLI のキャプチャは当初 claude の 1 本だけで、他 3 バックエンドは `stream_fixtures` が
  pending として報告していた。**その後 4 本とも揃い**（codex 0.154.0 / copilot 1.0.80 /
  grok 0.2.101）、`hook_payload` のペイロードも記述子が組む argv でフックを実際に発火させて
  採り直した。そこで **記録が実物とずれていた箇所が 2 つ**出た: copilot 1.0.80 は `toolArgs` を
  JSON 文字列ではなくオブジェクトで送る（`normalize_payload` は両方受けるのでゲートは開いて
  いなかった）、grok の `search_replace` はパスを `target_file` ではなく `file_path` で送る
  （`target_file` は `read_file` の形）。fixture を「読んだもの」ではなく「採ったもの」に
  限る方針が、実際にこの 2 つを見つけたということでもある。
- **P6**: `handbook/ADAPTER_DEVELOPMENT.md` を記述子の書き方と「先に測る項目」に書き換えた。

### その後の追加: `process`（#777）

記述子に 1 フィールド `process = "oneshot" | "duplex"` が増えた。ADR 009 当時は「1 ターン =
1 プロセス」が全バックエンド共通の前提だったので、`response.stdin` はプロセスの終わり方を語る
フィールドで済んでいた。常駐プロセス（`architecture/duplex-transport.md`）はその前提を
バックエンドごとの選択に変える。

意味論は**既定ではなく上限**にした。「このバックエンドが走らせられる最も高機能なプロセスモデル」
であって、実際に走るモデルではない。1 フィールドで「既定は oneshot のまま」と「claude だけが
duplex を選べる」の両方を表せるのはこの解釈だけで、既定として読むと `duplex` を宣言した瞬間に
全チャットの挙動が変わってしまう。チャット単位の選択は `backends.<id>.process` と frontmatter の
`process:` で、descriptor が宣言していなければどちらも無視される。

名前が `transport` でないのは、同じ記述子の `hook.transport` が既にその語を取っているため
（`settings_file` / `config_override` / `plugin_dir` / `project_dir`、conformance 2 本が分岐に
使っている）。

`stream()` が 1 本であるという P0 の結論は変わっていない。分岐は 1 箇所、ターンの後始末
（`finish`）とプロセスの後始末（`close_process`）を分けた上で、duplex が後者を設定しないという
形に落ちている。canonical イベントは 11 種から 12 種になった（`turn_end`）。増えた理由は
「ターンが終わった」を語る腕が 1 つも無く、成功した `result` 行がイベントを 1 つも生んで
いなかったため — oneshot ではプロセス終了がそれを代弁していた。

## Consequences

**得るもの**

- バックエンド追加の作業が「記述子 1 ファイル ＋ fixture」に縮む（既存戦略の範囲内なら）。
- 「Claude が正」が文章ではなく conformance suite になる。CLI 側のスキーマ変更で契約が外れたとき、
  落ちるスペックが C1〜C14 のどれかを名指す。
- ツール描画・`on_tool_use`・usage フッタ・限界検出がバックエンドで揃う。今日は揃っていない
  （描画形式、`FileChange` 特別扱い、codex だけの累積差分）。
- 共有コードからバックエンド名が消え、`.claude/rules/architecture.md` の不変条件が満たされる。

**払うもの**

- 記述子という間接層が 1 枚増える。`codex_command_builder.lua` を上から読めば分かった argv が、
  記述子 ＋ `request_builder` ＋ `extra_args` の 3 箇所に分かれる。argv スナップショットテスト
  （P2）がその読みにくさの代償。
- 描画を揃える P1 は、codex/copilot ユーザーの見た目を変える。
- 設定キーの移行（`permissions.codex_*` → `backends.codex.*`）。
- 戦略モジュールと逃げ道が残る以上、「コードを一切書かずに済む」とは言えない。上の「限界」節が
  その境界で、境界を記述子に明示させることがこの設計の主眼である。

## Alternatives considered

- **JSON パス式だけでデコーダを宣言する。** grok/copilot は書けるが Claude の 3 段合成と
  `vim.NIL` 罠が書けず、2 系統になる。却下。
- **`stream()` を per-adapter のまま残す（現状維持）。** `module-map.md` の判断。差分 7 点が
  すべて記述子フィールドで表せるので、根拠が消えた。
- **shell の方言分岐を Lua 側（`permission.lua`）へ移す。** `cli-integration.md` が既に却下している
  通り、handler がバックエンドを知る必要が生じ、`active_opts` が引けない fallback deny 経路で
  encoder を選べない。記述子は shell の引数を **選ぶ**だけにとどめる。
- **Agent SDK / app-server 系プロトコル（codex `app-server`, claude Agent SDK）へ寄せる。**
  ADR 003 が CLI 直接起動を選んだ経緯（依存の無さ、`--setting-sources` で得られるもの）は変わって
  いない。Gemini CLI も同じ headless JSONL の形なので、JSONL ＋ hook の抽象が最も広く当たる。

## References

- `.claude/rules/architecture.md` → "Backend Seams"、`handbook/architecture/cli-integration.md`
- `handbook/architecture/module-map.md`（「`stream()` は per-adapter」の現行判断）
- `handbook/architecture/lightweight-calls.md`（4 CLI の閉じ方の実測）
- `handbook/features/usage-limits.md` → "Which Channel Each Backend Has"
- #515（cli_runtime 抽出）、#516（vocabulary の受け渡し）、#537（3 つ直し忘れ）、#564（`allow` と `defer`）
- Gemini CLI: `docs/cli/headless.md`, `docs/hooks/reference.md`（google-gemini/gemini-cli、2026-09 時点。未実測）
