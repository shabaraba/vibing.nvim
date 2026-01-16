# vibing.nvim Lua ファイル行数集計レポート

## 📊 概要

- **合計ファイル数:** 188
- **合計行数:** 25,759行
- **平均ファイルサイズ:** 137行

---

## 📈 カテゴリ別分析

| カテゴリ           | ファイル数 | 合計行数 | 平均行数 | 割合  |
| ------------------ | ---------- | -------- | -------- | ----- |
| **Tests**          | 37         | 7,709    | 208      | 29.9% |
| **Infrastructure** | 32         | 4,142    | 129      | 16.1% |
| **UI**             | 12         | 3,120    | 260      | 12.1% |
| **Application**    | 36         | 3,113    | 86       | 12.1% |
| **Presentation**   | 22         | 2,845    | 129      | 11.0% |
| **Domain**         | 21         | 1,858    | 88       | 7.2%  |
| **Core**           | 17         | 1,229    | 72       | 4.8%  |
| **Root**           | 4          | 1,373    | 343      | 5.3%  |
| **Docs**           | 1          | 208      | 208      | 0.8%  |
| **Plugin**         | 1          | 75       | 75       | 0.3%  |
| **Ftplugin**       | 1          | 77       | 77       | 0.3%  |
| **Ftdetect**       | 1          | 10       | 10       | 0.0%  |

---

## 📋 詳細ファイル一覧

### 最大サイズファイル TOP 20

| ファイル                                          | 行数 |
| ------------------------------------------------- | ---- |
| lua/vibing/presentation/chat/buffer.lua           | 713  |
| lua/vibing/ui/inline_preview.lua                  | 586  |
| tests/chat_handlers_spec.lua                      | 519  |
| lua/vibing/ui/patch_viewer.lua                    | 467  |
| tests/oil_integration_spec.lua                    | 438  |
| lua/vibing/ui/permission_builder.lua              | 365  |
| lua/vibing/config.lua                             | 348  |
| lua/vibing/infrastructure/rpc/handlers/lsp.lua    | 340  |
| tests/chat_commands_spec.lua                      | 339  |
| lua/vibing/presentation/chat/modules/renderer.lua | 334  |
| lua/vibing/ui/command_picker.lua                  | 320  |
| tests/chat_buffer_spec.lua                        | 318  |
| lua/vibing/infrastructure/worktree/manager.lua    | 304  |
| tests/chat_actions_spec.lua                       | 302  |
| tests/actions_commands_spec.lua                   | 300  |
| tests/init_spec.lua                               | 297  |
| tests/session_permissions_spec.lua                | 285  |
| lua/vibing/ui/inline_picker.lua                   | 281  |
| lua/vibing/mcp/setup.lua                          | 279  |
| tests/context_spec.lua                            | 273  |

### Core 層 (1,229行)

**単一責任の原則に従うユーティリティと定数**

| ファイル                                    | 行数 | 説明                  |
| ------------------------------------------- | ---- | --------------------- |
| lua/vibing/core/utils/git.lua               | 152  | Git操作ユーティリティ |
| lua/vibing/core/utils/timestamp.lua         | 147  | タイムスタンプ処理    |
| lua/vibing/core/utils/file_path.lua         | 116  | ファイルパス操作      |
| lua/vibing/core/utils/language.lua          | 94   | 言語設定              |
| lua/vibing/core/utils/title_generator.lua   | 74   | タイトル生成          |
| lua/vibing/core/utils/git_diff.lua          | 74   | Git差分処理           |
| lua/vibing/core/utils/diff.lua              | 73   | 差分処理              |
| lua/vibing/core/utils/filename.lua          | 84   | ファイル名処理        |
| lua/vibing/core/utils/notify.lua            | 59   | 通知機能              |
| lua/vibing/core/utils/buffer_identifier.lua | 53   | バッファ識別子        |
| lua/vibing/core/utils/ui.lua                | 43   | UI ユーティリティ     |
| lua/vibing/core/utils/buffer_reload.lua     | 35   | バッファリロード      |
| lua/vibing/core/types.lua                   | 82   | 型定義                |
| lua/vibing/core/constants/actions.lua       | 50   | アクション定数        |
| lua/vibing/core/constants/tools.lua         | 46   | ツール定数            |
| lua/vibing/core/constants/modes.lua         | 38   | モード定数            |
| lua/vibing/core/constants/init.lua          | 9    | 定数初期化            |

### Domain 層 (1,858行)

**ビジネスロジックと不変性**

| ファイル                                                   | 行数 | 説明                  |
| ---------------------------------------------------------- | ---- | --------------------- |
| lua/vibing/domain/permissions/evaluator.lua                | 261  | パーミッション評価    |
| lua/vibing/domain/security/command_validator.lua           | 188  | コマンド検証          |
| lua/vibing/domain/security/path_sanitizer.lua              | 138  | パス検証              |
| lua/vibing/domain/squad/tests/integration_test.lua         | 154  | Squad統合テスト       |
| lua/vibing/domain/chat/session.lua                         | 131  | チャットセッション    |
| lua/vibing/domain/chat/message.lua                         | 109  | チャットメッセージ    |
| lua/vibing/domain/permissions/rule.lua                     | 95   | パーミッションルール  |
| lua/vibing/domain/squad/entity.lua                         | 82   | Squad エンティティ    |
| lua/vibing/domain/squad/value_objects/squad_name.lua       | 91   | Squad名               |
| lua/vibing/domain/inline/entity.lua                        | 68   | インラインアクション  |
| lua/vibing/domain/mention/entity.lua                       | 73   | メンション            |
| lua/vibing/domain/conversation/entity.lua                  | 69   | 会話                  |
| lua/vibing/domain/context/entity.lua                       | 66   | コンテキスト          |
| lua/vibing/domain/session/entity.lua                       | 60   | セッション            |
| lua/vibing/domain/squad/value_objects/squad_role.lua       | 48   | Squad ロール          |
| lua/vibing/domain/mention/value_objects/mention_status.lua | 46   | メンション状態        |
| lua/vibing/domain/mention/value_objects/mention_id.lua     | 45   | メンション ID         |
| lua/vibing/domain/mention/repository.lua                   | 30   | メンション リポジトリ |
| lua/vibing/domain/squad/services/naming_service.lua        | 50   | Squad命名サービス     |
| lua/vibing/domain/squad/services/collision_resolver.lua    | 40   | Squad衝突解決         |

### Application 層 (3,113行)

**ユースケースと編成**

| ファイル                                                         | 行数 | 説明                     |
| ---------------------------------------------------------------- | ---- | ------------------------ |
| lua/vibing/application/chat/commands.lua                         | 206  | チャットコマンド         |
| lua/vibing/application/chat/send_message.lua                     | 230  | メッセージ送信           |
| lua/vibing/application/chat/use_case.lua                         | 158  | チャットユースケース     |
| lua/vibing/application/chat/custom_commands.lua                  | 151  | カスタムコマンド         |
| lua/vibing/application/chat/completion.lua                       | 112  | コマンド補完             |
| lua/vibing/application/chat/init.lua                             | 101  | チャット初期化           |
| lua/vibing/application/inline/modules/execution.lua              | 201  | インライン実行           |
| lua/vibing/application/inline/use_case.lua                       | 129  | インラインユースケース   |
| lua/vibing/application/inline/executor.lua                       | 129  | インライン実行器         |
| lua/vibing/application/inline/queue_manager.lua                  | 115  | キュー管理               |
| lua/vibing/application/inline/modules/prompt_builder.lua         | 74   | プロンプトビルダー       |
| lua/vibing/application/inline/modules/action_config.lua          | 54   | アクション設定           |
| lua/vibing/application/inline/modules/task_queue.lua             | 43   | タスクキュー             |
| lua/vibing/application/inline/modules/unsaved_buffer.lua         | 58   | 未保存バッファ           |
| lua/vibing/application/context/manager.lua                       | 181  | コンテキストマネージャー |
| lua/vibing/application/mention/use_case.lua                      | 49   | メンションユースケース   |
| lua/vibing/application/mention/services/detector.lua             | 101  | メンション検出器         |
| lua/vibing/application/mention/services/notifier.lua             | 74   | メンション通知器         |
| lua/vibing/application/mention/services/interruption_checker.lua | 37   | 割り込み確認             |
| lua/vibing/application/mention/handlers/check_mentions.lua       | 54   | メンション確認           |
| lua/vibing/application/commands/handler.lua                      | 92   | コマンドハンドラー       |

### Presentation 層 (2,845行)

**UI制御とビューロジック**

| ファイル                                                        | 行数 | 説明                       |
| --------------------------------------------------------------- | ---- | -------------------------- |
| lua/vibing/presentation/chat/buffer.lua                         | 713  | チャットバッファ           |
| lua/vibing/presentation/chat/modules/renderer.lua               | 334  | レンダリング               |
| lua/vibing/presentation/chat/modules/frontmatter_handler.lua    | 201  | フロントマター処理         |
| lua/vibing/presentation/chat/view.lua                           | 176  | チャットビュー             |
| lua/vibing/presentation/inline/progress_view.lua                | 138  | 進捗表示                   |
| lua/vibing/presentation/chat/controller.lua                     | 123  | チャットコントローラー     |
| lua/vibing/presentation/chat/modules/patch_finder.lua           | 110  | パッチ検出                 |
| lua/vibing/presentation/chat/modules/keymap_handler.lua         | 96   | キーマップ処理             |
| lua/vibing/presentation/chat/modules/conversation_extractor.lua | 131  | 会話抽出                   |
| lua/vibing/presentation/chat/modules/file_manager.lua           | 85   | ファイル管理               |
| lua/vibing/presentation/chat/modules/window_manager.lua         | 69   | ウィンドウ管理             |
| lua/vibing/presentation/chat/modules/header_renderer.lua        | 74   | ヘッダーレンダリング       |
| lua/vibing/presentation/chat/modules/streaming_handler.lua      | 67   | ストリーミング処理         |
| lua/vibing/presentation/chat/modules/approval_parser.lua        | 81   | 承認パーサー               |
| lua/vibing/presentation/chat/modules/programmatic_sender.lua    | 80   | プログラム送信             |
| lua/vibing/presentation/chat/modules/collision_notifier.lua     | 40   | 衝突通知                   |
| lua/vibing/presentation/inline/controller.lua                   | 24   | インラインコントローラー   |
| lua/vibing/presentation/inline/output_view.lua                  | 125  | 出力ビュー                 |
| lua/vibing/presentation/context/controller.lua                  | 73   | コンテキストコントローラー |
| lua/vibing/presentation/common/window.lua                       | 82   | ウィンドウ共通機能         |
| lua/vibing/presentation/init.lua                                | 16   | Presentation初期化         |
| lua/vibing/presentation/chat/init.lua                           | 7    | チャット初期化             |

### Infrastructure 層 (4,142行)

**外部システムとの連携**

| ファイル                                                               | 行数 | 説明                       |
| ---------------------------------------------------------------------- | ---- | -------------------------- |
| lua/vibing/infrastructure/rpc/handlers/lsp.lua                         | 340  | LSPハンドラー              |
| lua/vibing/infrastructure/worktree/manager.lua                         | 304  | Worktree管理               |
| lua/vibing/infrastructure/rpc/handlers/window.lua                      | 261  | ウィンドウハンドラー       |
| lua/vibing/infrastructure/adapter/agent_sdk.lua                        | 228  | Agent SDK適配器            |
| lua/vibing/infrastructure/rpc/server.lua                               | 239  | RPCサーバー                |
| lua/vibing/infrastructure/adapter/modules/command_builder.lua          | 211  | コマンドビルダー           |
| lua/vibing/infrastructure/adapter/modules/event_processor.lua          | 177  | イベント処理               |
| lua/vibing/infrastructure/ui/factory.lua                               | 253  | UI ファクトリー            |
| lua/vibing/infrastructure/storage/frontmatter.lua                      | 194  | フロントマター保存         |
| lua/vibing/infrastructure/adapter/base.lua                             | 132  | 適配器ベース               |
| lua/vibing/infrastructure/rpc/registry.lua                             | 160  | RPCレジストリ              |
| lua/vibing/infrastructure/context/collector.lua                        | 140  | コンテキスト収集           |
| lua/vibing/infrastructure/nvim/command_validator.lua                   | 169  | コマンド検証               |
| lua/vibing/infrastructure/rpc/handlers/buffer.lua                      | 129  | バッファハンドラー         |
| lua/vibing/infrastructure/storage/patch_storage.lua                    | 128  | パッチ保存                 |
| lua/vibing/infrastructure/rpc/handlers/squad.lua                       | 127  | Squadハンドラー            |
| lua/vibing/infrastructure/adapter/modules/session_manager.lua          | 75   | セッション管理             |
| lua/vibing/infrastructure/adapter/modules/stream_handler.lua           | 80   | ストリーミングハンドラー   |
| lua/vibing/infrastructure/squad/registry.lua                           | 95   | Squad レジストリ           |
| lua/vibing/infrastructure/mention/rpc_handlers.lua                     | 100  | メンション RPC ハンドラー  |
| lua/vibing/infrastructure/mention/memory_repository.lua                | 84   | メンションリポジトリ       |
| lua/vibing/infrastructure/buffer/manager.lua                           | 83   | バッファマネージャー       |
| lua/vibing/infrastructure/file/writer.lua                              | 63   | ファイル書き込み           |
| lua/vibing/infrastructure/file/reader.lua                              | 59   | ファイル読み込み           |
| lua/vibing/infrastructure/storage/patch_parser.lua                     | 37   | パッチパーサー             |
| lua/vibing/infrastructure/context/formatter.lua                        | 54   | コンテキストフォーマッター |
| lua/vibing/infrastructure/squad/persistence/frontmatter_repository.lua | 50   | Squad永続化                |
| lua/vibing/infrastructure/rpc/handlers/init.lua                        | 56   | RPC初期化                  |
| lua/vibing/infrastructure/rpc/handlers/cursor.lua                      | 47   | カーソルハンドラー         |
| lua/vibing/infrastructure/rpc/handlers/execute.lua                     | 26   | 実行ハンドラー             |
| lua/vibing/infrastructure/rpc/handlers/message.lua                     | 20   | メッセージハンドラー       |
| lua/vibing/infrastructure/init.lua                                     | 21   | Infrastructure初期化       |

### UI 層 (3,120行)

**ユーザーインターフェース**

| ファイル                                  | 行数 | 説明                         |
| ----------------------------------------- | ---- | ---------------------------- |
| lua/vibing/ui/inline_preview.lua          | 586  | インラインプレビュー         |
| lua/vibing/ui/patch_viewer.lua            | 467  | パッチビューアー             |
| lua/vibing/ui/permission_builder.lua      | 365  | パーミッションビルダー       |
| lua/vibing/ui/command_picker.lua          | 320  | コマンドピッカー             |
| lua/vibing/ui/inline_picker.lua           | 281  | インラインピッカー           |
| lua/vibing/ui/gradient_animation.lua      | 226  | グラデーションアニメーション |
| lua/vibing/ui/output_buffer.lua           | 186  | 出力バッファ                 |
| lua/vibing/ui/inline_preview/handlers.lua | 208  | インラインハンドラー         |
| lua/vibing/ui/inline_preview/layout.lua   | 161  | インラインレイアウト         |
| lua/vibing/ui/inline_preview/renderer.lua | 125  | インラインレンダラー         |
| lua/vibing/ui/inline_preview/state.lua    | 114  | インライン状態               |
| lua/vibing/ui/inline_preview/keymaps.lua  | 81   | インラインキーマップ         |

### Root 層 (1,373行)

**メインエントリーポイント**

| ファイル                        | 行数 | 説明             |
| ------------------------------- | ---- | ---------------- |
| lua/vibing/init.lua             | 257  | メインモジュール |
| lua/vibing/config.lua           | 348  | 設定             |
| lua/vibing/install.lua          | 250  | インストール     |
| lua/vibing/mcp/setup.lua        | 279  | MCP設定          |
| lua/vibing/integrations/oil.lua | 184  | Oil統合          |
| lua/vibing/completion.lua       | 52   | 補完             |
| lua/vibing/constants/tools.lua  | 3    | ツール定数       |

### Tests (7,709行)

**テストスイート**

| ファイル                                                 | 行数 | 説明                           |
| -------------------------------------------------------- | ---- | ------------------------------ |
| tests/chat_handlers_spec.lua                             | 519  | チャットハンドラーテスト       |
| tests/oil_integration_spec.lua                           | 438  | Oil統合テスト                  |
| tests/chat_commands_spec.lua                             | 339  | チャットコマンドテスト         |
| tests/chat_buffer_spec.lua                               | 318  | チャットバッファテスト         |
| tests/chat_actions_spec.lua                              | 302  | チャットアクションテスト       |
| tests/actions_commands_spec.lua                          | 300  | アクション/コマンドテスト      |
| tests/init_spec.lua                                      | 297  | 初期化テスト                   |
| tests/session_permissions_spec.lua                       | 285  | セッションパーミッションテスト |
| tests/context_spec.lua                                   | 273  | コンテキストテスト             |
| tests/inline_spec.lua                                    | 271  | インラインアクションテスト     |
| tests/security_spec.lua                                  | 265  | セキュリティテスト             |
| tests/renderer_spec.lua                                  | 254  | レンダラーテスト               |
| tests/permission_builder_spec.lua                        | 240  | パーミッションビルダーテスト   |
| tests/agent_sdk_spec.lua                                 | 239  | Agent SDKテスト                |
| tests/timestamp_spec.lua                                 | 214  | タイムスタンプテスト           |
| tests/completion_spec.lua                                | 210  | 補完テスト                     |
| tests/collector_spec.lua                                 | 196  | コレクターテスト               |
| tests/chat_init_spec.lua                                 | 193  | チャット初期化テスト           |
| tests/permission_rules_spec.lua                          | 188  | パーミッションルールテスト     |
| tests/approval_parser_spec.lua                           | 170  | 承認パーサーテスト             |
| tests/formatter_spec.lua                                 | 168  | フォーマッターテスト           |
| tests/output_buffer_spec.lua                             | 167  | 出力バッファテスト             |
| tests/filename_spec.lua                                  | 120  | ファイル名テスト               |
| tests/language_spec.lua                                  | 111  | 言語テスト                     |
| tests/tools_spec.lua                                     | 76   | ツールテスト                   |
| tests/config_spec.lua                                    | 83   | 設定テスト                     |
| tests/lua/infrastructure/rpc/server_spec.lua             | 262  | RPC サーバーテスト             |
| tests/lua/infrastructure/rpc/registry_spec.lua           | 204  | RPC レジストリテスト           |
| tests/lua/infrastructure/rpc/handlers/execute_spec.lua   | 94   | 実行ハンドラーテスト           |
| tests/lua/infrastructure/storage/frontmatter_spec.lua    | 146  | フロントマターテスト           |
| tests/lua/infrastructure/nvim/command_validator_spec.lua | 142  | コマンド検証テスト             |
| tests/lua/domain/permissions/evaluator_spec.lua          | 200  | パーミッション評価テスト       |
| tests/lua/domain/chat/message_spec.lua                   | 103  | メッセージテスト               |
| tests/lua/application/inline/queue_manager_spec.lua      | 155  | キュー管理テスト               |
| tests/lua/minimal_init.lua                               | 9    | 最小初期化                     |
| tests/base_adapter_spec.lua                              | 133  | 適配器ベーステスト             |
| tests/minimal_init.lua                                   | 25   | 最小初期化                     |

---

## 🏗️ アーキテクチャ分析

### コード規模分布

```
Tests        ██████████████████ 29.9%
Infrastructure ████████ 16.1%
UI ██████ 12.1%
Application ██████ 12.1%
Presentation ███████ 11.0%
Domain ████ 7.2%
Core ███ 4.8%
Root ███ 5.3%
Other ① 1.1%
```

### 主要な観察

1. **テスト充実度が高い (30%)** - テストコードが全体の約30%を占める
2. **Infrastructure層が大きい (16%)** - RPCサーバーやアダプターなどの複雑性
3. **UI層が充実している (12%)** - ユーザーインターフェースに注力
4. **Application層が適度 (12%)** - ユースケースの実装が充実

### ファイルサイズ分析

**最大ファイル**

- `buffer.lua` (713行) - チャットバッファの主要ロジック
- `inline_preview.lua` (586行) - インラインプレビューの表示
- テストファイルが大きいのは網羅的なテストカバレッジが理由

**平均サイズ**

- 全体: 137行（バランスの取れた分割）
- Application層: 86行（単一責任の原則に従っている）
- Domain層: 88行（ビジネスロジックがコンパクト）
- Infrastructure層: 129行（やや大きいが複雑性の反映）

---

## 📍 改善提案

### ファイルサイズが大きいコンポーネント

1. **buffer.lua (713行)** → 分割検討
   - チャットバッファ管理の責務を分割可能

2. **inline_preview.lua (586行)** → 分割検討
   - プレビュー、レンダリング、イベント処理の分離

3. **patch_viewer.lua (467行)** → 分割検討
   - パッチ表示とインタラクションの分離

### テスト追加の機会

一部の重要なファイルにはテストが不足している可能性：

- UI層の一部モジュール
- Infrastructure層の特定のハンドラー

---

## ✅ まとめ

vibing.nvimは**188ファイル、25,759行**の適切に構造化されたプロジェクトです。

**強み：**

- ✓ 層別の適切な責務分割（Domain/Application/Presentation/Infrastructure）
- ✓ 充実したテストカバレッジ
- ✓ Core層の再利用可能なユーティリティ

**注視点：**

- buffer.luaやinline_preview.luaなど一部ファイルの大きさ
- UI層の複雑さ
