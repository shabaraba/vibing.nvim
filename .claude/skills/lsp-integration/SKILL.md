# LSP インテグレーションスキル

vibing.nvim の MCP サーバー経由で LSP を活用したコード分析を行います。

## 機能

### 1. バックグラウンドコード分析
- ファイルをバッファに読み込み、チャットから離れずに LSP 分析
- 型定義、参照、診断情報の取得
- 呼び出し階層の可視化

### 2. コード理解の強化
- シンボルの定義ジャンプなしでの確認
- 型情報とドキュメントの即座の取得
- プロジェクト全体の参照検索

### 3. リファクタリング支援
- 影響範囲の事前分析
- 型安全性の確認
- 未使用コードの検出

## MCP ツールの使用パターン

### 基本ワークフロー

```javascript
// 1. ファイルをバッファに読み込み（表示せずに）
const { bufnr } = await use_mcp_tool('vibing-nvim', 'nvim_load_buffer', {
  filepath: 'lua/vibing/actions/chat.lua'
});

// 2. バックグラウンドで LSP 分析
const symbols = await use_mcp_tool('vibing-nvim', 'nvim_lsp_document_symbols', {
  bufnr: bufnr
});

// 3. 特定のシンボルの型情報を取得
const hover = await use_mcp_tool('vibing-nvim', 'nvim_lsp_hover', {
  bufnr: bufnr,
  line: 10,
  col: 5
});

// 4. 診断情報（エラー・警告）を確認
const diagnostics = await use_mcp_tool('vibing-nvim', 'nvim_diagnostics', {
  bufnr: bufnr
});
```

## 自動アクティベーション

以下のリクエストで自動的に起動：
- 「この関数の型定義を確認して」
- 「エラーの原因を調査して」
- 「この変数がどこで使われているか調べて」
- 「呼び出し階層を確認して」
- 「未使用のコードを見つけて」

## メリット

- ✅ チャット画面から離れずに分析完了
- ✅ 複数ファイルの同時分析が可能
- ✅ LSP の正確な型情報を活用
- ✅ エディタの状態を変更しない
