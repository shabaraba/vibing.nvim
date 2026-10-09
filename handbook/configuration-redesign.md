# 設定構造の見直し案

状態: Issue [#879](https://github.com/shabaraba/vibing.nvim/issues/879) の実装・移行ガイド。
`feat/config-redesign` で新しい `setup()` スキーマを実装。

## 方針

設定を「何を変えたいか」で探せるようにする。既存の `agent` を分解し、
AIの用途別設定は `ai.chat` / `ai.helpers`、エージェント固有の設定は `ai.agents.<id>`、見た目は `ui`、自動実行は
`automation`、権限は `permissions` に集める。

キーの移動と挙動の変更を区別する。原則として既定の挙動は維持し、
削除する項目と意味を変更する項目だけを移行ガイドで明示する。
未知のキーや型違いを黙って無視せず、設定パスを含む診断を出す。
権限設定の誤りは安全な既定値への変更で済ませず、設定の適用を失敗させる。

現行の入口はLuaテーブルであり、ユーザー設定用JSONの読込機能はない。
新しい構造はJSONでも表現できるが、今回JSONファイルの読込機能は追加しない。

## よく使う設定の例

```lua
require("vibing").setup({
  ai = {
    chat = { agent = "claude", model = "sonnet" },
    helpers = { agent = "claude", model = "haiku", effort = "low" },
  },
  chat = { language = "ja" },
  ui = { window = { position = "right", width = 0.4 } },
  permissions = { ask = { "Bash" }, deny = {} },
})
```

省略した値には既定値が入る。この例ではモデルを指定しているが、単に
日本語で使うだけなら `setup({ chat = { language = "ja" } })` でよい。
配列は置換なので `deny = {}` は既定のBash拒否を外す。
同梱の破壊的コマンド拒否ルールや内部ツールの扱いは引き続き適用する。

`agent` はClaude・Codexなどの実行エージェント、`model` はそのエージェントに渡すモデルIDを指す。
`backend` / `adapter` は公開設定から除き、実装上の呼称としてのみ使う。
`helpers` はタイトル生成・要約・チャット検索・日報などの補助処理を指す。
内部ではツールもチャットセッションのresumeも使わない呼び出しとして実行する。
公開設定では実行方式ではなく用途で名前を付ける。

補助処理は通常チャットと独立してエージェント・モデル・推論量を選択できる。
例えば以下は、通常チャットをClaude、補助処理をCodexにする設定。

```lua
ai = {
  chat = { agent = "claude", model = "sonnet", effort = "high" },
  helpers = { agent = "codex", model = "モデルID", effort = "low" },
}
```

`モデルID` は利用可能なCodexモデルIDに置き換える。別CLIで補助処理を
する場合は、そのCLIのインストール・認証も必要。失敗時に別CLIやモデルへ
黙って切り替えない。`ai.helpers.agent` の省略時は `ai.chat.agent` を使う。
補助処理のモデルを省略した場合は、そのCLIの補助処理用の既定値を使う。

## トップレベルの責務

| キー           | ユーザーが変えるもの                                                         |
| -------------- | ---------------------------------------------------------------------------- |
| `ai`           | 通常チャット・補助処理それぞれのエージェント、モデル、推論量と固有オプション |
| `chat`         | 言語、保存、コンテキスト管理、日報                                           |
| `ui`           | ウィンドウ、出力、折り返し、アニメーション、diff表示                         |
| `keymaps`      | チャット内の操作キー                                                         |
| `permissions`  | 許可・拒否・確認、承認待ち、代理承認                                         |
| `automation`   | リミット後の継続・予約、複数チャットの並列度・通知                           |
| `integrations` | Neovimとの接続、プラグイン読込、DAP連携                                      |

トップレベルの数を減らすこと自体は目的にしない。`advanced` や `misc` の
ような、追加項目が何でも入り込める入れ物は作らない。

## 旧設定からの対応

| 現行                                                                       | 提案                                                          |
| -------------------------------------------------------------------------- | ------------------------------------------------------------- |
| `adapter`                                                                  | `ai.chat.agent`                                               |
| `agent.default_mode`                                                       | 削除。frontmatterのメタデータを作るだけで実行の挙動を変えない |
| `agent.default_model`, `agent.default_effort`                              | `ai.chat.model`, `.effort`                                    |
| `agent.utility_model`, `agent.utility_effort`                              | `ai.helpers.model`, `.effort`                                 |
| 新設                                                                       | `ai.helpers.agent`（通常チャットと独立したエージェント選択）  |
| `agent.setting_sources`                                                    | `ai.agents.claude.settings.sources`                           |
| `agent.git_instructions`                                                   | `ai.agents.claude.extensions.git_instructions`                |
| `agent.env`                                                                | `ai.agents.claude.env`                                        |
| `agent.mcp.user_servers`                                                   | `ai.agents.claude.mcp.inherit_cli_servers`                    |
| `agent.plugins`                                                            | `integrations.plugins`                                        |
| `agent.subagent.enabled`, `.show_prefix`                                   | `ui.subagents.show_output`, `.show_prefix`                    |
| `agent.token_usage.enabled`                                                | `ui.usage.enabled`                                            |
| `agent.token_usage.warn_context`                                           | `chat.context.warn_tokens`                                    |
| `agent.token_usage.cache_ttl_sec`                                          | `chat.context.cache_ttl_sec`                                  |
| `agent.token_usage.auto_compact`                                           | `chat.context.compaction`                                     |
| `agent.token_usage.auto_compact.at`                                        | `chat.context.compaction.threshold_tokens`                    |
| `agent.auto_resume_on_limit`                                               | `automation.limits.resume`                                    |
| `agent.scheduled_requests`                                                 | `automation.limits.queue`                                     |
| `agent.auto_resume_on_limit.prompt`                                        | `automation.limits.continue_prompt`                           |
| `agent.auto_resume_on_limit.fallback_delay_sec`, `.grace_sec`              | `automation.limits.fallback_delay_sec`, `.grace_sec`          |
| `agent.orchestration.max_concurrent`                                       | `automation.orchestration.max_concurrent`                     |
| `agent.orchestration.max_concurrent_subagents`                             | `automation.orchestration.max_concurrent_subagents`           |
| `agent.orchestration.delegated_approval`                                   | `permissions.delegated_approval`                              |
| `agent.chat_notifications`                                                 | `automation.orchestration.notifications`                      |
| `chat.window`                                                              | `ui.window`                                                   |
| `chat.auto_context`                                                        | `chat.context.auto_include`                                   |
| `chat.save_location_type`, `chat.save_dir`                                 | `chat.storage.location`, `.path`                              |
| `language`                                                                 | `chat.language`                                               |
| `daily_summary`                                                            | `chat.daily_summary`                                          |
| `ui.tool_result_display`, `ui.tool_markers`                                | `ui.tools.results`, `.markers`                                |
| `diff.layout`, `.fill_char`, `.highlights`                                 | `ui.diff.layout`, `.fill_char`, `.highlights`                 |
| `diff.tool`                                                                | 削除。現行の `git` と `auto` は同義                           |
| `mcp.enabled`, `mcp.rpc_port`                                              | `integrations.nvim.enabled`, `.port`                          |
| `dap`                                                                      | `integrations.dap`                                            |
| その他の `permissions.*`, `keymaps.*`, `ui.wrap`, `ui.gradient`, `ui.fold` | 維持                                                          |
| `backends.<id>.process`                                                    | `ai.agents.<id>.process`                                      |
| `backends.grok.executable`                                                 | `ai.agents.grok.path`                                         |
| その他の `backends.<id>.*`                                                 | `ai.agents.<id>.extensions.*`                                 |
| `backends.codex.auto_approve`                                              | `ai.agents.codex.extensions.auto_approve`                     |
| `backends.codex.auto_approve_ask`                                          | `ai.agents.codex.extensions.auto_approve_ask`                 |

## エージェント設定の共通構造

各エージェントは `path`, `process`, `env`, `settings`, `mcp`, `extensions` を持つ。
共通のdefaultsテーブルは設けず、それぞれ独立して指定する。
`path` は省略時にPATHからエージェントの実行ファイルを探す。`"auto"` は不要。
エージェント固有の機能は `extensions` にまとめる。
共通項目でも対応可能な値は異なるため、未対応の指定は黙って無視せず診断する。
この共通化には実装が必要で、現行で全エージェントが同じ項目を受け付けるわけではない。

Codexの固有設定は、以下をすべて含める。先に会話で示した全体例には
`auto_approve` と `auto_approve_ask` が抜けていたため補完する。

```lua
extensions = {
  approval_policy = "",
  auto_approve = false,
  auto_approve_ask = {},
  profile_file = ".vibing/codex-permissions.toml",
  -- profile_content = "...", -- 省略時は同梱テンプレート
  allow_tracked_profile = false,
  provider_notice = true,
}
```

`auto_approve` はCodex自身のsandbox外実行などの承認を自動で答える設定。
`auto_approve_ask` は、自動承認を有効にしても人間に確認する例外リスト。
vibing.nvimの `permissions.ask` とは判定対象が違うので統合しない。

## 設定の照合結果

現在の `config.lua` の既定値・型注釈と、`agents.lua` の `config_fields` を照合した。
上記のCodex2項目を補完し、現行設定には維持・移動・削除の行き先がある。
空の `backends.copilot` は設定項目として数えず、自由キーのmarkers/envは表ごと移す。
既定値に現れない任意項目も以下の通り維持する。

| 現行の任意項目                                                                                  | 提案                             |
| ----------------------------------------------------------------------------------------------- | -------------------------------- |
| `chat.window.height`                                                                            | `ui.window.height`               |
| `agent.token_usage.auto_compact.focus`                                                          | `chat.context.compaction.focus`  |
| `language.default`, `language.chat`                                                             | `chat.language.default`, `.chat` |
| `daily_summary.save_dir`                                                                        | `chat.daily_summary.save_dir`    |
| `permissions.rules` の `tools`, `paths`, `commands`, `patterns`, `domains`, `action`, `message` | すべて維持                       |

実装前に確定・検証する事項:

- `settings.sources` / `mcp.inherit_cli_servers` の各agentでの対応範囲。
  空オブジェクト・項目省略はagentの既定に従い、未対応の明示指定は診断する。
- 非Claudeのモデル省略時の既定と、agent切替時のモデルの解決。
  `sonnet` / `haiku` を全agentの既定モデルとして入れない。
- `path` / `env` の全agentでの反映。予約済み環境変数の保護と、補助処理に
  envを渡す範囲も定義する（現行のClaude用envは補助処理には渡らない）。
- `chat.storage.path` の省略時の保存先を維持する。
  現行のcustom保存先の既定値は `stdpath("data") .. "/vibing/chats"`。
- `ui.usage.enabled` から警告を分離する意味変更と、その移行案内。

`VIBING_NODE_EXECUTABLE` はビルド用の環境変数、プロジェクトのsystem promptは
別ファイルであり、どちらもsetup設定に取り込まない。

## 権限設定

今回は `operations` を導入せず、従来のツール単位の `allow`, `deny`, `ask`,
`rules` と評価順を維持する。操作カテゴリへの変換や、新しい優先順位は導入しない。
既存チャットの `permissions_allow`, `permissions_deny`, `permissions_ask` 等も
従来の形式・解釈を維持し、権限設定のためのfrontmatter変更は不要。

現行の公開ツール名は主にClaudeの語彙を共通名として使う。
Codexの `apply_patch` は `Edit`、Copilotの `view` は `Read`、
`bash` は `Bash` に変換される。ただし一対一の意味対応ではない。
例えば `apply_patch` は複数ファイルの作成・更新・削除を含みうるが、
現行のパス判定は単一の `file_path` を想定するため、Codexの編集には適用できない。

上記の意味対応・パス判定の制限は、設定構造の整理で解消したとは扱わない。
CLI自身のsandbox・承認設定は引き続きエージェント固有設定として別に扱う。

`inherit_cli_servers` はユーザー・プロジェクト・localのCLI由来MCP設定全体を
指す。現行の `user_servers` はユーザースコープだけを切り替える名前に見えるが、
実際にはそれ以外も無効になるため名称を改める。Claudeのみで利用可能。

`ui.usage.enabled` は内訳の表示だけを制御する。警告は `warn_tokens = 0`、
送信前のキャッシュ確認は `cache_ttl_sec = 0` で無効にする。
現行の `token_usage.enabled = false` からの移行では、表示と両方の通知を
止める3項目を案内する。圧縮は独立した設定として扱う。

言語設定は文字列と `{ default, chat }` の形式を維持する。置き場所を変えても
補助処理の言語継承は残す。日報も同じチャット群を使うため `chat` に置く。

## 解決・検証のルール

1. 通常・補助処理のエージェント・モデル・推論量は用途ごとに解決する。
   未指定のモデルは選択したCLIの記述子の既定値を使い、他CLIのモデル名を変換しない。
   Claudeの既定は現在の `sonnet` / `haiku` を維持する。
   他CLIはCLI既定に任せるか明示的な補助処理用モデルを持つかを記述子で決める。
   設定したモデルIDは、補完候補にないことを理由に拒否しない。
2. 通常ターンはリクエスト・frontmatterによる上書きを優先する。
   frontmatterが `ai.chat.agent` と別のCLIを指定しモデルが未指定なら、そのCLIの既定値を使う。
   補助処理は専用のエージェント・モデル・推論量を使い、チャットの上書きを継承しない。
   既存の通常チャット用adapterをそのまま使わず、用途の設定から実行先を選ぶ。
3. 公開する設定は一つだけとし、内部でも同じ構造を使う。
   旧構造への変換を恒久的な内部表現として残さない。
4. オブジェクトは再帰マージ、配列は全置換。空配列は「既定の配列を空にする」。
   許可リストが空のときの権限評価は現行仕様を維持し、明記する。
5. `enabled` は機能のスイッチ、`show_*` は表示のスイッチ。
   `ui.subagents.show_output` は表示のためCLIの転送設定も有効にするが、
   サブエージェントの起動許可は制御しない。
6. 秒は `_sec`、ミリ秒は `_ms`、トークン数は `_tokens` を付ける。
   `ui.gradient.interval` は `interval_ms` へ改名する。
7. 未知のキー、旧キー、誤った型、未対応のバックエンド専用設定を診断する。
   旧キーには新パスを添える。設定適用前に検証し、失敗時は一部だけ適用しない。
   マーカーや環境変数などの自由キー領域は明示して許容する。
8. バックエンドの能力上限、権限の評価順、内部ツール、承認待ちの期限関係を維持する。
   名前の変更を理由にCLI側の承認やsandboxを統合しない。

## 入力形式

第一案はLuaの `setup(table)` を維持する。同じデータ構造をJSONでも扱えるため、
JSON対応を後で足しても別スキーマを作らずに済む。

JSON読込も必要なら、明示的な読込APIを追加し、Luaと同じ検証器を通す。
設定ファイルの自動探索やプロジェクト設定の自動適用は今回の整理と切り分ける。
JSONでは省略を「既定値を使用」、`null` は不許可とし、無効化は各項目の
`false` / `0` / 空配列などで表す。JSONのオブジェクトと配列の区別を保つ。

## 実装順と完了条件

1. 公開構造と既定値・検証を定義する。既存のバックエンド登録を唯一の定義元にする。
2. 設定の参照箇所を新構造へ変更し、モデル解決を共有する。
   タイトル・要約・検索・日報の呼び出し先を共通の補助処理の入口で解決する。
3. 旧キーの移行表と診断を用意する。旧キーを黙って残す互換層は作らない。
4. READMEの短い導入例、設定リファレンス、ヘルプ、関連skill・ルールのパスを更新する。
5. 通常チャット・補助処理のエージェント/モデル分離、CLI切替、空配列、誤設定、権限評価、保存先、
   表示と自動処理の分離を検証する。Lua/Nodeテスト、構文・docチェックを通す。
   E2Eはプロジェクトの手順に従って別途実行する。

保存済みチャットのfrontmatterは設定APIと別の永続化形式として扱う。
今回のキー変更を理由に既存チャットの `agent`, `model`, `effort` 等を改名しない。
明示的に保存されたモデル・推論量を引き続き尊重する。

実装対象は Issue [#879](https://github.com/shabaraba/vibing.nvim/issues/879)。
チャット検索は補助モデルを使うが、検索専用ツールを利用する従来の制限付きagent実行を維持する。
タイトル生成・要約・日報は従来のツールなし実行を維持する。

## 検証記録

- `npm test`: Lua / Node / MCP とimport監査を通過。
- `npm run check` / `npm run check:doc`: 通過。
- `npm run test:e2e`: 追加した設定・frontmatter・保存先・失敗時の設定保持を含めて通過。
  初回はmacOSの `/var` / `/private/var` 表記差で保存先の比較が失敗し、実体パス比較へ修正。
- 13種類のmutationを適用し、それぞれ対応するassertionの失敗を確認。元ファイルから復元済み。
- agentの行動評価は全体実行の先頭ケースが失敗した一方、同じケースの単独再実行では1/1成功。
  全体評価は途中停止し、全ケースの通過は未確認。行動評価の安定性は追加調査が必要。

| 意図的に壊した挙動                   | 検出したテスト                                             |
| ------------------------------------ | ---------------------------------------------------------- |
| 空配列の置換                         | config: merges objects and replaces lists                  |
| 自由キーのobjectマージ               | config: merges free-form marker objects                    |
| 検証失敗時の設定保持                 | config: leaves the last valid config intact                |
| 補助agentの独立選択                  | helper_adapter: selects and caches independently           |
| 補助モデルへのチャットモデル混入     | non_claude_model: never leaks the chat model               |
| 異agentのsession再利用               | summarize: sends conversation text for a different agent   |
| 補助CLIの終了処理                    | shutdown: cancels helper requests before RPC stop          |
| 明示pathの反映・存在しないpathの拒否 | request_builder_path: explicit/missing path（3 agents）    |
| モデル補完のpath反映                 | catalog: configured agent executable                       |
| 補助処理のagent env                  | agent_environment: applies agent env to helpers            |
| 使用量表示OFF時のcontext警告         | token_usage_report: retains context warnings               |
| agentごとのenv選択                   | agent_environment: environment of each selected agent      |
| 異agentへのfrontmatter既定値の混入   | renderer: does not inherit another agent's model or effort |
