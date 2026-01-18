# vibing.nvim E2Eテストケース

このディレクトリには、vibing.nvimプラグインの全機能をカバーするEnd-to-End (E2E) テストケースが含まれています。

## 📋 テストケース一覧

### チャット機能

1. **[01-chat-basic-flow.md](./01-chat-basic-flow.md)** - チャット基本フロー
   - 新規チャットセッションの作成
   - メッセージ送信とストリーミングレスポンス
   - セッションIDの管理
   - チャットのキャンセルと保存

2. **[02-chat-window-positions.md](./02-chat-window-positions.md)** - チャットウィンドウ配置
   - 各種ウィンドウ位置（current, right, left, top, bottom, back, float）
   - 既存チャットファイルの再開
   - 複数チャットウィンドウの同時管理

3. **[03-chat-session-persistence.md](./03-chat-session-persistence.md)** - チャットセッション永続化
   - チャットファイルの保存と読み込み
   - フロントマターの管理
   - セッション破損時の自動リセット
   - 会話履歴の完全性

### MCP/RPC機能

4. **[04-mcp-rpc-server.md](./04-mcp-rpc-server.md)** - MCPサーバー/RPC機能
   - RPCサーバーの起動と管理
   - バッファ/カーソル/ウィンドウ操作ハンドラー
   - LSP操作ハンドラー
   - シェルコマンド実行

### コンテキスト管理

5. **[05-context-management.md](./05-context-management.md)** - コンテキスト管理機能
   - ファイルのコンテキスト追加
   - Visual範囲の追加
   - oil.nvim統合（複数ファイル選択）
   - 自動コンテキスト収集
   - プロンプトへの統合

### インライン機能

6. **[06-inline-actions.md](./06-inline-actions.md)** - インライン機能
   - 事前定義アクション（fix, feat, explain, refactor, test）
   - カスタムプロンプト
   - プレビューモードとダイレクトモード
   - タスクキュー管理

### ウィンドウ/バッファ管理

7. **[07-window-buffer-management.md](./07-window-buffer-management.md)** - ウィンドウ/バッファ管理
   - バッファの作成と識別
   - ウィンドウフォーカス管理
   - ウィンドウリサイズ
   - フローティングウィンドウ
   - バッファのクリーンアップ

### Worktree統合

8. **[08-worktree-integration.md](./08-worktree-integration.md)** - Worktree統合機能
   - git worktreeの自動作成
   - 設定ファイルのコピー
   - node_modulesの共有
   - チャットファイルの永続化
   - 複数worktreeの管理

## 🎯 テスト実施方法

### 前提条件

1. Neovim 0.9.0以上がインストールされている
2. vibing.nvimプラグインがインストールされている
3. Claude Agent SDKが設定されている
4. Node.jsがインストールされている（MCPテスト用）
5. gitがインストールされている（Worktreeテスト用）

### 手動テスト

各mdファイルを開いて、記載されているテスト手順に従って実施してください。

```vim
:edit docs/e2e-tests/01-chat-basic-flow.md
```

### 自動テスト（将来の実装）

将来的には、以下のツールを使った自動E2Eテストの実装を検討しています：

- **busted** - Luaテストフレームワーク
- **plenary.nvim** - Neovimテストユーティリティ
- **vusted** - Vim/Luaテストフレームワーク

## 📊 テストカバレッジ

### 機能別カバレッジ

| 機能分類            | テストケース数 | 優先度      |
| ------------------- | -------------- | ----------- |
| チャット機能        | 3              | 🔴 Critical |
| MCP/RPC             | 1              | 🟠 High     |
| コンテキスト管理    | 1              | 🟠 High     |
| インライン機能      | 1              | 🟡 Medium   |
| ウィンドウ/バッファ | 1              | 🟡 Medium   |
| Worktree統合        | 1              | 🟢 Low      |
| **合計**            | **8**          | -           |

### テストタイプ別

- **正常系テスト**: 各ケースの基本フロー
- **異常系テスト**: エラーハンドリング、無効な入力
- **パフォーマンステスト**: 大量データ、連続実行

## 🚀 テスト実施の推奨順序

1. **Phase 1: コア機能** (必須)
   - 01-chat-basic-flow.md
   - 02-chat-window-positions.md
   - 03-chat-session-persistence.md

2. **Phase 2: 統合機能** (推奨)
   - 04-mcp-rpc-server.md
   - 05-context-management.md

3. **Phase 3: 拡張機能** (オプション)
   - 06-inline-actions.md
   - 07-window-buffer-management.md
   - 08-worktree-integration.md

## 📝 テスト結果の記録

各テストケースの実施後、以下の情報を記録してください：

```markdown
## テスト実施記録

- **実施日**: 2026-01-XX
- **実施者**: [名前]
- **環境**:
  - OS: macOS / Linux / Windows
  - Neovim: vX.X.X
  - vibing.nvim: commit hash
- **結果**: ✅ Pass / ❌ Fail
- **備考**: [問題点や気づいた点]
```

## 🐛 バグ報告

テスト中にバグを発見した場合は、以下の情報を含めてGitHub Issueを作成してください：

1. **テストケースID** (例: E2E-CHAT-001)
2. **再現手順**
3. **期待される動作**
4. **実際の動作**
5. **エラーメッセージ** (あれば)
6. **環境情報**

## 🔄 テストケースの更新

テストケースは以下の場合に更新が必要です：

- 新機能の追加
- 既存機能の仕様変更
- バグ修正による動作の変更
- パフォーマンス要件の変更

## 📚 関連ドキュメント

- [vibing.nvim README](../../README.md)
- [アーキテクチャドキュメント](../architecture/) (作成予定)
- [APIリファレンス](../api/) (作成予定)

## 🎓 テスト設計の原則

これらのE2Eテストケースは以下の原則に基づいて設計されています：

1. **ユーザー視点**: 実際のユーザーの操作フローを模倣
2. **包括性**: 正常系・異常系・境界値テスト
3. **独立性**: 各テストケースは独立して実行可能
4. **再現性**: 同じ手順で同じ結果が得られる
5. **明確性**: 期待される動作が明確に記述されている

## 📞 サポート

テストに関する質問や問題がある場合は、以下の方法でサポートを受けられます：

- GitHub Issues: [vibing.nvim/issues](https://github.com/shabaraba/vibing.nvim/issues)
- Discussions: [vibing.nvim/discussions](https://github.com/shabaraba/vibing.nvim/discussions)

---

最終更新: 2026-01-17
