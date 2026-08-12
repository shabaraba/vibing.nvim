# GitHub Copilot CLI アダプター設計

## 背景と目的

vibing.nvim は現在 `claude` と `codex` の 2 バックエンドを選択できる。ここに GitHub Copilot CLI
(`copilot`) を 3 つ目の選択肢として追加する。

選択方法は既存と同じ 2 経路:

- グローバル: `require("vibing").setup({ adapter = "copilot" })`
- チャット単位: フロントマターの `agent: copilot`

## CLI 調査結果 (copilot 1.0.78)

実機で検証済みの事実。

| 必要な機能           | copilot CLI での実現                                | 判定      |
| -------------------- | --------------------------------------------------- | --------- |
| 非対話実行           | `-p/--prompt`                                       | ✅        |
| JSONL ストリーム     | `--output-format json`                              | ✅        |
| 逐次表示             | `assistant.message_delta` イベントの `deltaContent` | ✅        |
| セッション再開       | `--resume=<id>`、`result` イベントの `sessionId`    | ✅ 検証済 |
| モデル指定           | `--model`                                           | ✅        |
| 作業ディレクトリ     | `vim.system` の `cwd`（`-C` は不要）                | ✅        |
| MCP 登録             | `copilot mcp add`                                   | ✅        |
| 実行ごとのフック注入 | **無し**                                            | ❌        |

セッション再開の検証: `-p` で得た `result.sessionId` を `--resume=<id>` に渡すと文脈が保持され、
`sessionId` は再開後も同一だった。既存の frontmatter `session_id` 機構をそのまま流用できる。

**フック注入が不可能な理由**: copilot はフックイベント `preToolUse` / `preMcpToolCall` /
`permissionRequest` を持つが、定義できるのは `~/.copilot/config.json` の `hooks` キーか
リポジトリの `.github/hooks/*.json` のみ。codex の `-c hooks.pre_tool_use=[...]` に相当する
実行ごとの注入フラグが存在しない。よってツール承認 UI は本スコープ外とする（後述）。

## アーキテクチャ

既存の `codex_cli` と同型の構成を取る。Adapter 基底クラスを継承し、責務ごとに modules へ分割する。

### 新規ファイル

| ファイル                                            | 行数目安 | 責務                              |
| --------------------------------------------------- | -------- | --------------------------------- |
| `lua/vibing/infrastructure/adapter/copilot_cli.lua` | ~200     | stream / cancel / セッション管理  |
| `.../adapter/modules/copilot_command_builder.lua`   | ~130     | コマンド配列構築                  |
| `.../adapter/modules/copilot_event_processor.lua`   | ~140     | JSONL イベント → chunk / tool_use |
| `.../adapter/modules/copilot_item_display.lua`      | ~100     | ツール実行結果の Markdown 整形    |
| `lua/vibing/infrastructure/adapter/factory.lua`     | ~30      | エージェント名 → アダプターの解決 |

`stream_handler` / `session_manager` / `active_stream_registry` / `hook_cleanup` は既存モジュールを
そのまま再利用する。

### factory.lua を切り出す理由

現在 `init.lua:56` と `send_message.lua:_resolve_adapter` の 2 箇所に同一の `claude` / `codex`
分岐が重複している。3 つ目を足すと重複が悪化するため、テーブル駆動の factory に集約して両方から
呼ぶ。今回の作業に直接関わる範囲に限定し、無関係なリファクタは行わない。

```lua
local ADAPTERS = {
  claude = "vibing.infrastructure.adapter.claude_cli",
  codex = "vibing.infrastructure.adapter.codex_cli",
  copilot = "vibing.infrastructure.adapter.copilot_cli",
}

local ADAPTER_NAMES = {
  claude = "claude_cli",
  codex = "codex_cli",
  copilot = "copilot_cli",
}
```

`M.create(agent_type, config)` と `M.adapter_name(agent_type)` を公開する。未知の値は `claude` に
フォールバックする（既存の `_resolve_adapter` の挙動を維持）。

### 既存ファイルの変更点

| ファイル                                                                        | 変更内容                                               |
| ------------------------------------------------------------------------------- | ------------------------------------------------------ |
| `lua/vibing/core/constants/modes.lua`                                           | `VALID_AGENTS` に `"copilot"` を追加                   |
| `lua/vibing/config.lua`                                                         | `adapter` の型注釈を `"claude"\|"codex"\|"copilot"` に |
| `lua/vibing/init.lua`                                                           | アダプター生成を factory 経由に置換                    |
| `lua/vibing/application/chat/send_message.lua`                                  | `_resolve_adapter` を factory 経由に置換               |
| `lua/vibing/infrastructure/init.lua`                                            | `CopilotCLIAdapter` をエクスポート                     |
| `.../completion/providers/frontmatter.lua`                                      | `agent` enum と `COPILOT_MODELS` を追加（後述）        |
| `build.sh`                                                                      | `copilot mcp add vibing-nvim` を追加                   |
| `README.md` / `README.ja.md` / `docs/configuration.md` / `doc/api-reference.md` | copilot バックエンドの記載                             |

## コマンド構築

```text
copilot -p <prompt> --output-format json --stream on --no-color
        [--resume=<session_id>]
        [--model <model>]
        <権限フラグ>
```

### モデル解決

codex と同じ `resolve_model` 方針を取る。`Modes.is_valid_model()` が真になる短縮名
(`sonnet` / `opus` / `haiku` / `fable`) は copilot では無効なモデル ID なので渡さず、copilot 側の
デフォルトに任せる。それ以外の文字列（`gpt-5.5`、`claude-sonnet-5`、`auto` など）はそのまま
`--model` に渡す。

### 権限モードのマッピング

copilot の非対話モードは `--allow-all-tools` が必須仕様のため、「allow-all した上で deny で
絞る」方向になる。

| vibing の permission_mode                      | copilot のフラグ                        |
| ---------------------------------------------- | --------------------------------------- |
| `plan`                                         | `--plan --allow-all-tools`              |
| `bypassPermissions`                            | `--allow-all`                           |
| `default` / `acceptEdits` / `auto` / `dontAsk` | `--allow-all-tools` + deny リストを展開 |

### deny リストの変換

`permissions.deny` の各エントリを copilot の permission pattern に変換して `--deny-tool` に渡す。
変換表に無い名前（`Read` / `Glob` / `Grep` など）は無視する。

| vibing                  | copilot        |
| ----------------------- | -------------- |
| `Bash`                  | `shell`        |
| `Bash(npm:*)`           | `shell(npm:*)` |
| `Write`, `Edit`         | `write`        |
| `WebFetch`, `WebSearch` | `url`          |

種別全体にマッチさせるときは **パーレンを付けない**。`shell()` のような空パーレンは CLI に
`Invalid rule format` で拒否される（実機で確認済み）。help の "the argument is optional" は
「引数を省略できる」ではなく「パーレンごと省略する」の意味。

`Write` と `Edit` が両方 deny にあっても `--deny-tool write` は 1 回だけ渡す（重複排除する）。

### コンテキストと言語

codex と同一。セッション新規作成時のみプロンプト先頭に付与する。

- コンテキスト: `Context file: <path>` を改行区切りで前置
- 言語: `Always respond in <名称> (<コード>).` を前置（`en` のときは付けない）

## イベント処理

`--output-format json` の JSONL を 1 行ずつパースし、以下にディスパッチする。

| copilot イベント          | 処理                                                                      |
| ------------------------- | ------------------------------------------------------------------------- |
| `assistant.turn_start`    | `onFirstResponse` を発火（セッション再開タイムアウトを解除）              |
| `assistant.message_delta` | `data.deltaContent` を chunk として逐次出力し、`messageId` を既出力に記録 |
| `assistant.message`       | 当該 `messageId` の delta を 1 つも受けていない場合のみ `content` を出力  |
| `tool.execution_start`    | `on_tool_use` 通知 + ツール見出しを出力                                   |
| `tool.execution_complete` | 実行結果を整形出力                                                        |
| `result`                  | `sessionId` を SessionManager に保存                                      |
| 上記以外                  | 無視                                                                      |

`onFirstResponse` を `assistant.turn_start` に割り当てるのは、`result` がストリーム最終行に来るため
そこで解除するとセッション破損検出タイムアウト (120 秒) が先に発火してしまうため。codex アダプタが
`thread.started` で解除しているのと同じ役割になる。

`assistant.message` をフォールバックに回すのは、`--stream off` が設定で強制された場合などに delta
が届かず応答が空になるのを防ぐため。`messageId` 単位の記録テーブルは `wrapped_on_done` で破棄する。

`assistant.message.toolRequests` は表示に使わない。ツール表示は `tool.execution_start` /
`tool.execution_complete` の実行イベント側で行う（実際に実行されたものだけを表示するため）。

### ツール表示のフォーマット

`copilot_item_display.lua` が担当する。`codex_item_display.lua` と同じ見た目に揃える。

`toolName` をキーにしたフォーマッタテーブルで分岐する。

実機で確認した `toolName` と引数の形は次のとおり。

| copilot の `toolName` | 引数                         | 表示ラベル  |
| --------------------- | ---------------------------- | ----------- |
| `bash`                | `command`, `description`     | `Bash`      |
| `view`                | `path`                       | `Read`      |
| `create`              | `path`, `file_text`          | `Write`     |
| `edit`                | `path`, `old_str`, `new_str` | `Edit`      |
| `web_search`          | `query`                      | `WebSearch` |

- 引数サマリは `command` → `path` → `file_path` → `query` の順に拾い、`path` 系のときだけ
  `on_tool_use` の第 2 引数（file_path）に渡す
- テーブルに無い `toolName`: ツール名をそのまま出し、引数は JSON エンコードして汎用表示にする
- 出力は長さ上限で切り詰める

`tool.execution_complete` の `error` は文字列ではなく `{ message, code }` のテーブルで届く
（ツールが deny されたときなど）。`tostring()` すると `table: 0x...` がチャットに漏れるため、
`message` を取り出して表示する。

## セッションとキャンセル

**セッション**: `result` イベントの `sessionId` を `SessionManagerModule.store()` で保存し、
既存機構が frontmatter の `session_id` に書き戻す。次回リクエストで `--resume=<id>` を付ける。

**キャンセル**: codex と同じく `pkill -9 -P <pid>` で子プロセスを先に落としてから親を kill する。
copilot も shell ツールで子プロセスを産み、それが stdout パイプを掴んだままだと `vim.system` の
exit ハンドラが発火せず UI が固まるため。

## フロントマター補完

`lua/vibing/infrastructure/completion/providers/frontmatter.lua` を更新する。

### agent フィールド

`ENUMS.agent` に 1 件追加する。

```lua
{ value = "copilot", description = "GitHub Copilot CLI" },
```

### model フィールド

`COPILOT_MODELS` を新設し、`M.get_model_values(agent)` の分岐に追加する。現在の 3 項演算子は
3 分岐になると読みにくいのでテーブル引きに変える。

```lua
local MODELS_BY_AGENT = {
  claude = CLAUDE_MODELS,
  codex = CODEX_MODELS,
  copilot = COPILOT_MODELS,
}

function M.get_model_values(agent)
  local models = MODELS_BY_AGENT[agent] or CLAUDE_MODELS
  ...
end
```

copilot のモデルカタログは 30 件以上あり全部出すと補完が使いづらいので、代表的なものに絞る。
（実際に利用可能なモデルは利用者のプランに依存するため、ここは候補提示であって検証ではない）

```lua
local COPILOT_MODELS = {
  { value = "auto", description = "Copilot に自動選択させる" },
  { value = "claude-sonnet-5", description = "Claude Sonnet 5" },
  { value = "claude-opus-5", description = "Claude Opus 5" },
  { value = "claude-haiku-4.5", description = "Claude Haiku 4.5 (fastest)" },
  { value = "gpt-5.5", description = "GPT-5.5" },
  { value = "gpt-5.4", description = "GPT-5.4" },
  { value = "gpt-5.4-mini", description = "GPT-5.4 Mini" },
  { value = "gpt-5.3-codex", description = "GPT-5.3 Codex" },
  { value = "gemini-3.1-pro-preview", description = "Gemini 3.1 Pro (preview)" },
}
```

`lua/vibing/application/completion/sources/frontmatter.lua` の `_read_frontmatter_agent` は
値をそのまま返す実装なので変更不要。型注釈のコメントのみ更新する。

## テスト

新規に 3 つの spec を追加する（`tests/*_spec.lua`、plenary.nvim）。

| ファイル                                 | 対象                                                                        |
| ---------------------------------------- | --------------------------------------------------------------------------- |
| `tests/copilot_command_builder_spec.lua` | 権限モード別のフラグ、deny 変換と重複排除、モデルフィルタ、resume、言語前置 |
| `tests/copilot_event_processor_spec.lua` | delta 出力、`assistant.message` フォールバック、sessionId 保存、ツール表示  |
| `tests/copilot_cli_spec.lua`             | インスタンス生成、`name`、`supports()`                                      |

既存の `tests/completion/frontmatter_spec.lua` に、`agent: copilot` のときに `COPILOT_MODELS` が
返ることと `agent` enum に `copilot` が含まれることのケースを追加する。

E2E は copilot の GitHub 認証が必要なため既存スイートには含めない（codex アダプタも同様に E2E を
持たない）。動作確認は実際のチャットで手動実施する。

## スコープ外（後続 issue）

**ツール承認 UI**（チャットバッファ内の `⚠️ Tool approval required` プロンプト）。

copilot にはフックイベント `preToolUse` / `preMcpToolCall` / `permissionRequest` が実在するが、
定義できるのは `~/.copilot/config.json` の `hooks` キーかリポジトリの `.github/hooks/*.json` のみで、
codex の `-c hooks.pre_tool_use=[...]` に相当する実行ごとの注入フラグが無い。

後続 issue で検討する案:

1. `COPILOT_HOME` を vibing 生成のディレクトリに向けて `config.json` にフックを書く
   （認証情報も同ディレクトリに置かれるため、ユーザーの既存認証をどう引き継ぐかが課題）
2. リポジトリの `.github/hooks/` に一時的にフック定義を置く（ユーザーのリポジトリを汚す）
3. `--available-tools` / `--excluded-tools` による静的な絞り込みで代替する

本スコープの実装が動作確認できた後、この調査結果を添えて issue 化する。
