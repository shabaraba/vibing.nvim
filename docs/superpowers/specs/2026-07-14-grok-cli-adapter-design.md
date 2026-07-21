# vibing.nvim: Grok CLI アダプター設計

## 背景・目的

vibing.nvim は現在 Claude CLI（`claude_cli`）と OpenAI Codex CLI（`codex_cli`）の2つのバックエンドアダプターを持つ。
本設計は、xAI の Grok CLI を第3のバックエンド（`grok_cli`）として、Codex アダプターと同じパターンで追加するための設計案である。

ゴール:

- チャット frontmatter に `agent: grok` と書けば Grok CLI で会話できる
- セッション再開（`session_id` frontmatter）、権限モード、モデル選択、ツール実行の表示が Claude/Codex と同等に動く
- 既存の共通モジュール（`stream_handler.lua`, `session_manager.lua`, `tool_display.lua`, `bin/hooks/pre-tool-use.sh`）を最大限再利用する

## 前提調査 1: 「grok cli」は2つ存在する

同名バイナリ `grok` を提供する無関係なツールが2つあり、どちらを対象にするか明確に決める必要がある。

| | 公式: xAI「Grok Build」 | コミュニティ: `superagent-ai/grok-cli` |
| --- | --- | --- |
| 提供元 | xAI 公式 | Superagent（xAI 非公式） |
| インストール | `curl -fsSL https://x.ai/cli/install.sh \| bash` | `npm i -g grok-dev` |
| バイナリ名 | `grok`（`agent` の symlink あり） | `grok` |
| headless 実行 | `grok -p "..."` | `grok -p "..."` |
| 構造化出力 | `--output-format json \| streaming-json` | `--format json`（JSONL） |
| セッション再開 | `--resume <id>` / `-c` / `--fork-session`、`~/.grok/sessions` | `-s <id>` / `--session latest` |
| 権限制御 | `--permission-mode default\|acceptEdits\|bypassPermissions\|plan\|dontAsk`、`--always-approve`、`--sandbox strict` | `--sandbox`（macOS Apple Silicon 限定 microVM）程度 |
| MCP | Claude Code の `.mcp.json` / plugin 設定をそのまま自動発見 | `.grok/settings.json` の `mcpServers` |
| 設定ファイル | `~/.grok/config.toml`（TOML） | `~/.grok/user-settings.json`（JSON） |
| API キー | `XAI_API_KEY` | `GROK_API_KEY` |
| AGENTS.md / CLAUDE.md | 対応（明記あり） | AGENTS.md のみ |

**採用: 公式 xAI Grok Build CLI。** 理由:

1. `--permission-mode` の enum（`default`/`acceptEdits`/`bypassPermissions`/`plan`/`dontAsk`）が vibing.nvim の
   `permissions.mode` と **ほぼ 1:1** で対応する（Codex のように sandbox 語彙への翻訳が不要）
2. `session_id` を JSON 出力から読み戻して `--resume <id>` で再開でき、`--fork-session` まである
   （vibing.nvim の `session_id` frontmatter + fork 機構と直接対応）
3. MCP 設定が Claude Code 互換なので、vibing-nvim MCP サーバー（Claude Code plugin として登録済み）が
   追加設定なしで拾われる可能性が高い
4. コミュニティ版は権限制御が未成熟で、sandbox が macOS 限定

**バイナリ衝突への対策**: 両ツールとも `grok` を名乗り `~/.grok/` を共有するため、アダプター初期化時に
`grok --version` の出力をスニッフして公式版かどうかを判定し、コミュニティ版だった場合は
「公式 Grok Build CLI をインストールしてください」という明示的なエラーを出す。
`config.grok.executable`（後述）で明示パス指定も可能にする。

## 前提調査 2: 既存 Codex アダプターの構造（踏襲するパターン）

- **アダプター契約**（`infrastructure/adapter/base.lua`）: `new` / `execute` / `stream` / `cancel` / `supports` +
  `session` サポート時は `set_session_id` / `get_session_id` / `cleanup_session` / `cleanup_stale_sessions`
- **モジュール分割**: アダプター本体（プロセス起動・キャンセル）、コマンドビルダー（argv 構築）、
  イベントプロセッサー（JSONL 1行→vibing イベント）、アイテムディスプレイ（ツール実行のチャット表示整形）
- **共通部品**: `stream_handler.lua`（stdout の行バッファリング＋exit ハンドラー生成）と
  `session_manager.lua`（handle_id→session_id 管理）はアダプター非依存でそのまま再利用可能
- **完了検知**: JSONL に done イベントはなく、**プロセス exit** で `on_done` を発火する
- **セッション破損検知**: resume 時に 120 秒以内に最初のイベントが来なければ強制 kill して
  `_session_corrupted = true` を返す（イベントプロセッサーが `context.onFirstResponse()` を必ず呼ぶ必要がある）
- **権限フック**: `bin/hooks/pre-tool-use.sh`（stdin JSON + `VIBING_NVIM_RPC_PORT`/`VIBING_HANDLE_ID` 環境変数）を
  Codex は `-c hooks.pre_tool_use=[...]` で注入し、RPC 経由で Neovim 側の `permission.lua` に問い合わせる
- **ツール名エイリアス**: `permission.lua` の `CODEX_TOOL_ALIASES = { apply_patch = "Edit" }` により、
  frontmatter の `permissions_allow: [Edit]` 等がバックエンドを問わず機能する

## 設計: 新規ファイル

Codex のファイル構成を鏡写しにする。

### 1. `lua/vibing/infrastructure/adapter/grok_cli.lua`

`codex_cli.lua` を雛形にしたアダプター本体。

- `name = "grok_cli"`、`SUPPORTED_FEATURES = { streaming, tools, model_selection, context, session }` すべて true
- `stream()` で `GrokCommandBuilder.build()` → `vim.system()` 起動。環境変数は既存と同じ
  （`VIBING_NVIM_RPC_PORT`, `VIBING_RPC_PORT`, `VIBING_NVIM_CONTEXT`, `VIBING_HANDLE_ID`）+ 必要なら `XAI_API_KEY` は継承のみ（値の管理はしない）
- `perm_handler.set_active_opts(handle_id, vim.tbl_extend("force", opts, { _is_grok = true }))`（`_is_codex` と同型）
- resume 時の 120 秒タイムアウト＋`_session_corrupted` 処理を Codex と同一実装で持つ
- `cancel()`: まず Claude 型のシンプル kill で実装し、実機検証で Grok が子プロセスに stdout パイプを
  握らせる挙動（Codex の gotcha）が確認されたら `pkill -9 -P <pid>` の2段 kill に切り替える

### 2. `lua/vibing/infrastructure/adapter/modules/grok_command_builder.lua`

argv 構築。基本形:

```
grok -p "<prompt>" --output-format streaming-json [-d <cwd>] [--model <m>] [--permission-mode <mode>] [--resume <session_id>]
```

- **バイナリ解決**: `config.grok.executable`（明示パス）→ `vim.fn.exepath("grok")`。キャッシュし、
  見つからなければエラー。初回のみ `--version` スニッフで公式版判定
- **headless**: `-p <prompt>` + `--output-format streaming-json`（Codex の `exec --json` 相当）
- **resume**: `opts._session_id` があれば `--resume <session_id>` を追加。`opts._is_fork` なら
  さらに `--fork-session`（SDK の forkSession に直接対応 — Codex より素直に fork を実装できる）
- **権限モード**: `resolve_permission_mode(opts)` — vibing の `permission_mode` をそのまま
  `--permission-mode <mode>` に渡す（`auto` のみ Grok に存在しないため `default` にフォールバック）。
  `bypassPermissions` は `--permission-mode bypassPermissions`（実機で通らなければ `--always-approve` を併用）
- **モデル**: Codex の `resolve_model` と同じガードを実装 — `opts.model or config.agent.default_model` が
  Claude モデル名（`Modes.VALID_MODELS`）だったらフラグを**省略**して Grok 側デフォルト
  （`grok-build-0.1`）に任せる。Grok モデル名（`grok-4.5`, `grok-code-fast-1` 等）は自由入力で通す。
  ※ headless の `--model` フラグの存在は要実機確認（無ければ `~/.grok/config.toml` 経由 or 省略）
- **cwd**: `-d <cwd>` を明示（worktree の `working_dir` frontmatter 対応のため。`vim.system` の cwd オプションと二重でも害はない）
- **コンテキスト/言語プレフィックス**: Codex と同一 — 新規セッションのみ `Context file: <path>` 行と
  `Always respond in <lang>` 行をプロンプト先頭に付与。resume 時は生プロンプト
- **フック注入**: Grok Build にはフックシステム（stdin JSON / exit code 2 でブロック）があり
  Claude Code 互換を謳っているため、まず `~/.grok/` を汚さない注入方法（CLI フラグ or 一時 settings）を
  実機調査する。注入手段が確立するまでは、権限制御を `--permission-mode` だけで運用する
  **フェーズ1（フックなし）** と、`pre-tool-use.sh` 再利用の **フェーズ2（Tool Approval UI 完全対応）** に分ける（後述）

### 3. `lua/vibing/infrastructure/adapter/modules/grok_event_processor.lua`

streaming-json の 1 行 → vibing イベントへの変換。調査で **2系統のイベント語彙**が確認されており
（ドキュメント合成の限界）、どちらが実際の出力かは実機検証が必須:

- 系統A: `step_start` / `text` / `tool_use` / `step_finish` / `error`
- 系統B: `session.start` / `model.thinking` / `tool.call` / `tool.result` / `model.message` / `session.end`

設計上のマッピング（系統Bベース。系統Aだった場合はキー名を差し替えるだけで構造は同じ）:

| Grok イベント | 処理 | vibing シグナル |
| --- | --- | --- |
| `session.start`（or `step_start` 初回） | `session_id` を SessionManager へ保存、`context.onFirstResponse()` | セッション ID 捕捉 + resume タイムアウト解除 |
| `model.message` / `text` | `emit_chunk(item.text)` | `on_chunk`（本文ストリーム） |
| `model.thinking` | `"\n💭 %s\n"` 形式で emit（Codex の `reasoning` と同一表示） | `on_chunk` |
| `tool.call` / `tool_use` | `GrokItemDisplay` でヘッダー整形 + `opts.on_tool_use(tool, file_path, command)` 発火 | ツール表示 + Modified Files 追跡 |
| `tool.result` | `ToolDisplay.format_result_text(...)` で `tool_result_display` 設定に従い整形 | `on_chunk` |
| `error` | `errorOutput` へ蓄積 | プロセス exit 時に `response.error` |
| `session.end` / `step_finish` | no-op（完了はプロセス exit 駆動 — Codex と同じ方針） | — |
| 未知 type | `true` を返して黙殺（Codex と同じ・将来イベント耐性） | — |

**重要**: 最初に到達したイベントで必ず `context.onFirstResponse()` を呼ぶこと
（呼ばないと resume が毎回「破損」判定されセッションがリセットされ続ける — Codex 実装で確認済みの罠）。

`usage`（`prompt_tokens` 等）は初期実装では読み捨てる（Claude/Codex アダプターにもトークン表示はないため）。

### 4. `lua/vibing/infrastructure/adapter/modules/grok_item_display.lua`

`codex_item_display.lua` の縮小版。`tool_display.lua` の `resolve_marker` / `format_result_text` /
`get_display_mode` を再利用し、ツール呼び出しヘッダー（`⏺ Bash(npm test)` 形式）、ファイル変更、
MCP ツール呼び出し（`⏺ MCP(server:tool)`）の整形を担当。Grok のツール名（`read_file` 等が確認されている）を
表示用にそのまま出すか Claude 風名称に寄せるかは、権限エイリアス表（後述）と整合させる。

## 設計: 既存ファイルの変更

新規アダプター追加時に触るべき登録ポイント（コード確認済み）:

| ファイル | 変更内容 |
| --- | --- |
| `lua/vibing/core/constants/modes.lua` | `VALID_AGENTS = { "claude", "codex", "grok" }` |
| `lua/vibing/infrastructure/init.lua` | `M.GrokCLIAdapter = require(...)` を export に追加 |
| `lua/vibing/init.lua` | setup 内の `if adapter == "codex" ... else ...` を if/elseif/else 化（または `{ claude=..., codex=..., grok=... }` のルックアップテーブル化を推奨） |
| `lua/vibing/application/chat/send_message.lua` | `_resolve_adapter` の `expected_name = agent_type == "codex" and "codex_cli" or "claude_cli"`（L497）を `AGENT_TO_ADAPTER_NAME = { claude = "claude_cli", codex = "codex_cli", grok = "grok_cli" }` のマップに置換。アダプター生成分岐（L503-508）に grok アームを追加 |
| `lua/vibing/config.lua` | `@field adapter? "claude"\|"codex"\|"grok"` 注釈更新 + `grok = { executable = "auto" }` セクション追加 |
| `lua/vibing/infrastructure/completion/providers/frontmatter.lua` | `ENUMS.agent` に `"grok"` 追加、`GROK_MODELS = { "grok-build-0.1", "grok-4.5", "grok-4", "grok-code-fast-1" }` を追加し `get_model_values(agent)` に grok 分岐 |
| `lua/vibing/infrastructure/rpc/handlers/permission.lua` | `GROK_TOOL_ALIASES` 追加（Grok ネイティブツール名 → Claude 正準名。例: `read_file = "Read"`, `edit_file/apply_patch = "Edit"`, `bash/shell = "Bash"` — 実機でツール名を採取して確定）。`_is_codex` と同型の `_is_grok` フラグ分岐 |
| `build.sh` | （フェーズ2）Grok が MCP 登録コマンドを持つ場合に vibing-nvim MCP サーバー登録ブロックを追加。Claude Code 設定の自動発見が効くなら不要 — 要検証 |
| `README.md` / `CHANGELOG.md` / `docs/ADAPTER_DEVELOPMENT.md` | アダプター表・構成図・設定例に grok を追記。ADAPTER_DEVELOPMENT.md は現状 `lua/vibing/adapters/` 等の**古いパス・存在しないアダプター名を記載しており stale** — 本対応のついでに現行構成（`infrastructure/adapter/`）へ更新する |

変更不要（そのまま動く）:

- `lua/vibing/application/completion/sources/frontmatter.lua`（`agent:` を汎用に読むため provider 側の変更のみで追従）
- `stream_handler.lua` / `session_manager.lua` / `active_stream_registry` / `bin/hooks/pre-tool-use.sh`

## 権限モードのマッピング表

| vibing `permission_mode` | Codex（参考: sandbox 翻訳が必要） | **Grok（そのまま渡せる）** |
| --- | --- | --- |
| `default` | `-s workspace-write` | `--permission-mode default` |
| `acceptEdits` | `-s workspace-write` | `--permission-mode acceptEdits` |
| `plan` | `-s read-only` | `--permission-mode plan` |
| `dontAsk` | `-s workspace-write` | `--permission-mode dontAsk` |
| `bypassPermissions` | `--dangerously-bypass-approvals-and-sandbox` | `--permission-mode bypassPermissions` |
| `auto` | `-s workspace-write` | `default` にフォールバック（Grok に無い） |

この 1:1 対応が Grok を Codex より統合しやすくしている最大のポイント。

## 実装フェーズ

**フェーズ1: 基本統合（フックなし）**

1. 実機検証スパイク: `grok --help` / `grok -p "hello" --output-format streaming-json` の生出力を採取し、
   イベント語彙（系統A/B）、`--model` フラグ有無、exit code、stderr ノイズ、stdin 挙動、
   `--permission-mode` の headless での受理、resume 時に併用不可なフラグ、を確定する
2. 4つの新規ファイル + 登録ポイント変更を実装
3. 権限制御は `--permission-mode` のみ（Tool Approval UI・granular rules は Grok では未サポートと README に明記）
4. ユニットテスト: `tests/lua/infrastructure/adapter/modules/grok_command_builder_spec.lua` と
   `grok_event_processor_spec.lua`（既存 `cli_command_builder_spec.lua` の構造を踏襲。
   ※ Codex にはビルダー/プロセッサーのテストが存在しないという既知のカバレッジギャップがある — Grok では最初から書く）

**フェーズ2: 権限フック統合（Tool Approval UI 対応）**

1. Grok のフックシステム（stdin JSON、exit code 2 = block）に `bin/hooks/pre-tool-use.sh` を注入する
   手段を確立（Codex の `-c hooks.pre_tool_use=[...]` 相当のフラグ、または一時 config）
2. `grok_settings_generator.lua`（`codex_settings_generator.lua` 相当）を追加
3. `permission.lua` の `_is_grok` 分岐 + `GROK_TOOL_ALIASES` を実ツール名で確定
4. E2E テスト（`tests/e2e/grok_adapter_spec.lua`）— ただし CI/開発環境に `grok` バイナリと
   `XAI_API_KEY` が必要なため、バイナリ不在時は skip するガードを入れる

**フェーズ3（任意・将来）: ACP モード**

Grok Build は stdio JSON-RPC の ACP エージェントモード（`grok agent stdio`）を持つ。
プロセスを張りっぱなしにする常駐型統合が可能だが、既存アーキテクチャ（1メッセージ=1プロセス + resume）から
大きく逸脱するため本設計のスコープ外とし、将来の ADR 候補として記録するに留める。

## リスク・要実機検証項目（フェーズ1着手前チェックリスト）

1. **streaming-json のイベントスキーマ**（系統A vs 系統B）— パーサー実装の前提。最重要
2. **headless での `--model` フラグの有無** — 無ければモデル切替は config.toml 経由になり `/model` の UX が制限される
3. **プロセス exit code 契約** — フック用の exit code（0/2/その他）しか文書化されていない
4. **stderr の常時ノイズ** — Codex の `"Reading additional input from stdin..."` 相当があれば
   フィルタしないと全リクエストがエラー扱いになる（`stream_handler` は非空 stderr をエラー視）
5. **stdin 挙動** — `-p` 指定時に stdin を待つ場合は Codex 同様 `stdin = ""` を明示
6. **cancel 時の子プロセス** — ツール実行用の子が stdout を握るなら 2 段 kill が必須
7. **resume 併用不可フラグ** — Codex の「resume は `-s` を受けない」相当の制約
8. **MCP 自動発見の実挙動** — vibing-nvim MCP サーバー（Claude Code plugin 登録）を Grok が本当に拾うか
9. **バイナリ衝突** — `grok-dev`（コミュニティ版）が PATH にいるケースの検出とエラーメッセージ
10. **サブスクリプション/API キー要件** — headless は `XAI_API_KEY` で動くが、ユーザーへの案内を README に明記
