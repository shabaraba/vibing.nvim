# vibing.nvim リファクタリング設計 (修正版)

## 修正方針

issue #269の要件を最優先とし、以下の原則でリファクタリングを実施します：

1. **既存のディレクトリ構造を尊重** - 新しいレイヤーを作らず、既存の構造内で分割
2. **200行以下を厳守** - 理想は100行、最大200行
3. **段階的な移行** - 既存コードを壊さず、段階的にリファクタリング
4. **issue #269の優先順位に従う**

## 対象ファイルと分割計画

### 🔴 最優先 (Week 1)

#### 1. `ui/inline_preview.lua` (1159行) → 6ファイルに分割

**現在の責務:**

- 状態管理 (State)
- UI構築 (3パネルレイアウト)
- Diff生成・表示
- ファイルリスト管理
- キーマップ処理
- 会話ファイル保存

**分割後:**

```
ui/inline_preview/
├── init.lua                    (~50行) - エントリーポイント、setup()
├── state.lua                   (~80行) - 状態管理、初期化
├── layout.lua                  (~150行) - 3パネルレイアウト構築
├── file_list.lua               (~120行) - ファイルリスト表示・選択
├── diff_viewer.lua             (~150行) - Diff生成・表示・ナビゲーション
├── response_panel.lua          (~100行) - レスポンス表示
├── keymaps.lua                 (~120行) - キーマップ登録・処理
└── conversation_saver.lua      (~180行) - 会話ファイル保存・Git操作
```

**実装戦略:**

1. `state.lua`を先に抽出（他のモジュールが依存）
2. `layout.lua`でパネル配置ロジックを分離
3. 各パネルの処理を個別モジュールに抽出
4. `init.lua`で全体を統合

---

#### 2. `presentation/chat/buffer.lua` (1086行) → 7ファイルに分割

**現在の責務:**

- バッファ作成・管理
- ウィンドウ作成・配置
- レンダリング (Markdown、タイムスタンプ、グラデーション)
- キーマップ処理
- コンテキスト表示
- フロントマター更新
- ストリーミング応答処理

**分割後:**

```
presentation/chat/
├── buffer.lua                  (~150行) - バッファ管理のみ
├── window_manager.lua          (~120行) - ウィンドウ作成・配置
├── renderer.lua                (~150行) - Markdown描画・構文ハイライト
├── streaming_handler.lua       (~100行) - ストリーミング応答処理
├── gradient_renderer.lua       (~80行) - グラデーションアニメーション
├── keymap_handler.lua          (~150行) - キーマップ登録・処理
├── context_display.lua         (~120行) - コンテキスト表示・管理
└── frontmatter_updater.lua     (~100行) - フロントマター更新
```

**実装戦略:**

1. `window_manager.lua`でウィンドウ生成を分離
2. `renderer.lua`でレンダリングロジックを抽出
3. `streaming_handler.lua`でストリーミング処理を分離
4. `buffer.lua`を薄いコーディネーターに変更

---

### 🟡 中優先 (Week 2)

#### 3. `application/inline/use_case.lua` (472行) → 5ファイルに分割

**現在の責務:**

- アクション実行 (fix, feat, explain, refactor, test)
- プロンプト生成
- ストリーミング処理
- エラーハンドリング
- プレビュー起動

**分割後:**

```
application/inline/
├── use_case.lua                (~100行) - ユースケースコーディネーター
├── actions/
│   ├── fix.lua                 (~80行) - Fix アクション
│   ├── feat.lua                (~80行) - Feat アクション
│   ├── explain.lua             (~80行) - Explain アクション
│   ├── refactor.lua            (~80行) - Refactor アクション
│   └── test.lua                (~80行) - Test アクション
└── prompt_builder.lua          (~100行) - プロンプト生成
```

**実装戦略:**

1. 各アクションを個別ファイルに抽出（戦略パターン）
2. `prompt_builder.lua`でプロンプト生成ロジックを共通化
3. `use_case.lua`をアクション選択・実行のみに簡素化

---

#### 4. `infrastructure/adapter/agent_sdk.lua` (405行) → 4ファイルに分割

**現在の責務:**

- Agent SDK通信
- ストリーミングパース
- 権限チェック
- セッション管理
- イベント処理

**分割後:**

```
infrastructure/adapter/
├── agent_sdk.lua               (~100行) - アダプターインターフェース
├── stream_parser.lua           (~120行) - JSON-linesパース
├── permission_checker.lua      (~100行) - 権限チェック統合
└── event_handler.lua           (~150行) - イベント処理ロジック
```

**実装戦略:**

1. `stream_parser.lua`でパース処理を分離
2. `permission_checker.lua`で権限チェックを独立
3. `event_handler.lua`でイベント処理を抽出
4. `agent_sdk.lua`を薄いファサードに変更

---

#### 5. `ui/permission_builder.lua` (365行) → 3ファイルに分割

**現在の責務:**

- UIピッカー表示
- ツール選択処理
- ルール編集
- フロントマター更新

**分割後:**

```
ui/permission_builder/
├── init.lua                    (~80行) - エントリーポイント
├── picker.lua                  (~150行) - UIピッカー表示・選択
├── rule_editor.lua             (~100行) - ルール編集UI
└── frontmatter_sync.lua        (~80行) - フロントマター同期
```

---

#### 6. `infrastructure/rpc/handlers/lsp.lua` (340行) → 5ファイルに分割

**現在の責務:**

- LSP定義取得
- LSP参照検索
- Hover情報取得
- Diagnostics取得
- Call Hierarchy処理

**分割後:**

```
infrastructure/rpc/handlers/lsp/
├── init.lua                    (~50行) - ハンドラー登録
├── definition.lua              (~80行) - 定義取得
├── references.lua              (~80行) - 参照検索
├── hover.lua                   (~80行) - Hover情報
└── diagnostics.lua             (~80行) - Diagnostics取得
```

---

#### 7. `ui/command_picker.lua` (312行) → 3ファイルに分割

**現在の責務:**

- コマンドピッカーUI
- コマンド実行
- 履歴管理

**分割後:**

```
ui/command_picker/
├── init.lua                    (~80行) - エントリーポイント
├── picker_ui.lua               (~150行) - ピッカーUI表示
└── command_executor.lua        (~100行) - コマンド実行・履歴
```

---

## アーキテクチャルール（既存構造に基づく）

### 既存のレイヤー構造を維持

```
domain/           - ビジネスロジック（依存なし）
application/      - ユースケース（domainに依存）
presentation/     - UI層（applicationに依存）
infrastructure/   - 外部サービス（domainに依存）
ui/               - Legacy UI（段階的にpresentationへ移行）
```

### モジュール分割の原則

1. **100行を目標、200行を上限とする**
2. **1ファイル1責務（Single Responsibility）**
3. **関連するファイルはサブディレクトリにグループ化**
4. **init.luaで統合・エクスポート**

### 命名規則

- **モジュールファイル**: スネークケース (`file_list.lua`, `stream_parser.lua`)
- **クラス**: パスカルケース (`ChatBuffer`, `DiffViewer`)
- **関数**: スネークケース (`create_window`, `parse_event`)

---

## セキュリティ修正（変更なし）

以下のセキュリティ修正は、前回の設計通り実施します：

1. **Command Injection Prevention** - `domain/security/command_validator.lua`
2. **Path Traversal Prevention** - `domain/security/path_sanitizer.lua`
3. **Input Validation** - `domain/services/validation_service.lua`
4. **Environment Variable Protection** - `infrastructure/adapter/agent_sdk.lua`

---

## 実装計画（3週間）

### Week 1: 最優先ファイルの分割

#### Day 1-3: `ui/inline_preview.lua` の分割

- Day 1: `state.lua`, `layout.lua` 抽出
- Day 2: `file_list.lua`, `diff_viewer.lua` 抽出
- Day 3: `response_panel.lua`, `keymaps.lua`, `conversation_saver.lua` 抽出

**検証:**

```bash
# 既存機能が動作することを確認
:'<,'>VibingInline fix
# プレビューUIが正常に表示されること
```

#### Day 4-7: `presentation/chat/buffer.lua` の分割

- Day 4: `window_manager.lua`, `renderer.lua` 抽出
- Day 5: `streaming_handler.lua`, `gradient_renderer.lua` 抽出
- Day 6: `keymap_handler.lua`, `context_display.lua` 抽出
- Day 7: `frontmatter_updater.lua` 抽出、統合テスト

**検証:**

```bash
# 既存機能が動作することを確認
:VibingChat
# チャットが正常に動作すること
# ストリーミングが正常に動作すること
# グラデーションアニメーションが動作すること
```

---

### Week 2: 中優先ファイルの分割

#### Day 8-10: Application層の分割

- Day 8: `application/inline/use_case.lua` 分割
  - `actions/*.lua` 抽出
  - `prompt_builder.lua` 抽出
- Day 9: `infrastructure/adapter/agent_sdk.lua` 分割
  - `stream_parser.lua`, `permission_checker.lua` 抽出
- Day 10: 統合テスト

#### Day 11-14: UI層の分割

- Day 11: `ui/permission_builder.lua` 分割
- Day 12: `infrastructure/rpc/handlers/lsp.lua` 分割
- Day 13: `ui/command_picker.lua` 分割
- Day 14: 統合テスト、ドキュメント更新

---

### Week 3: セキュリティ強化・テスト・レビュー

#### Day 15-17: セキュリティ強化

- Day 15: `domain/security/path_sanitizer.lua` 実装
- Day 16: `domain/security/command_validator.lua` 実装
- Day 17: セキュリティテスト

#### Day 18-21: QA・レビュー・完了

- Day 18-19: QAテスト、回帰テスト
- Day 20: コードレビュー、修正
- Day 21: 最終確認、ドキュメント完成

---

## 完了条件

- [ ] すべての対象ファイルが200行以下になっている
- [ ] 既存のテストがすべてパスする
- [ ] 新規追加のセキュリティテストがパスする
- [ ] 機能に変更がない（回帰なし）
- [ ] ドキュメントが更新されている
- [ ] issue #269 がクローズできる状態

---

## リスク評価

| リスク               | 影響   | 軽減策                                         |
| -------------------- | ------ | ---------------------------------------------- |
| 既存機能の破壊       | High   | 段階的移行、各ステップでの動作確認             |
| テストカバレッジ不足 | High   | 手動テスト追加、回帰テストチェックリスト作成   |
| ファイル数の増加     | Medium | サブディレクトリでグループ化、init.luaで簡潔化 |
| パフォーマンス劣化   | Low    | ベンチマーク測定（必要に応じて）               |

---

## 前回設計との変更点

### 変更した点

1. **既存ディレクトリ構造を尊重** - 新しいレイヤー（domain/application/infrastructure）を追加せず、既存構造内で分割
2. **issue #269の優先順位に従う** - 行数の多いファイルから順に対応
3. **分割の細かさ** - 100行を目標とし、より細かく分割
4. **実装順序** - 最も大きなファイルから先に対応

### 維持した点

1. **セキュリティ修正** - コマンドインジェクション、パストラバーサル対策は継続
2. **単一責任の原則** - 1ファイル1責務を厳守
3. **段階的移行** - 既存コードを壊さず、段階的にリファクタリング
4. **テスト重視** - 各ステップで動作確認

---

## 次のステップ

この修正設計を確認いただき、承認後に実装を開始します。

**確認事項:**

1. ✅ issue #269の要件を満たしているか
2. ✅ 既存のディレクトリ構造を尊重しているか
3. ✅ 200行以下の目標が達成可能か
4. ✅ 実装計画（3週間）は妥当か
