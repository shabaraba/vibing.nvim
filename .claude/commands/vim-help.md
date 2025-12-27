---
description: Neovim の vimdoc 形式のヘルプドキュメントを生成
---

現在のモジュールまたは関数に対して、Neovim の `:help` 形式（vimdoc）のドキュメントを生成してください。

## 要件

1. **フォーマット**
   - 80 文字幅に収める
   - 適切なタグ（`*tag*`）の設置
   - セクション区切り（`====`, `----`）

2. **内容**
   - INTRODUCTION: 機能の概要
   - USAGE: 基本的な使い方
   - CONFIGURATION: 設定オプション
   - COMMANDS: ユーザーコマンド
   - FUNCTIONS: 公開関数 API
   - EXAMPLES: 実用例

3. **スタイル**
   - `:h dev-help` に準拠
   - コードブロックは `>` でインデント
   - キーワードは `|keyword|` でリンク

## 出力

`doc/` ディレクトリに配置可能な完全な vimdoc ファイルを生成してください。
