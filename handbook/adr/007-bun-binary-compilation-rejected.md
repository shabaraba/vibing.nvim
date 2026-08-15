# ADR 007: Bun Binary Compilation Rejected

**Status:** Rejected

**Date:** 2026-01-11

**Decision Maker:** Development Team

## Context

vibing.nvimでは、Agent SDKラッパー（`bin/agent-wrapper.ts`）をNode.js + esbuildでバンドルしたJSファイルとして配布しています。起動速度の向上を目的として、bunの`--compile`オプションを使用したスタンドアロンバイナリ化を検討しました。

### 検討した実装

1. **ビルドプロセス**
   - esbuildでJSバンドル生成（従来通り）
   - bunの`bun build --compile`でスタンドアロンバイナリ生成
   - バイナリは`dist/bin/native/vibing-agent`に配置

2. **設定オプション**
   - `node.use_binary`: true/false でバイナリ使用を切り替え
   - `node.dev_mode`: trueの場合はTypeScriptを直接実行（優先）

3. **期待されるメリット**
   - 起動速度の向上（Node.js起動オーバーヘッドの削減）
   - 依存関係のバンドル（node_modules不要）
   - 配布の簡素化

## Problem: Agent SDK Compatibility Issues

bunの`--compile`でバイナリ化を試みた結果、以下のエラーが発生しました：

```
{"type":"error","message":"Claude Code executable not found at /$bunfs/root/cli.js. Is options.pathToClaudeCodeExecutable set?"}
```

### 根本原因

1. **Agent SDKの内部実装**
   - `@anthropic-ai/claude-agent-sdk`は内部でファイルシステムアクセスを行っている
   - Claude Code CLIの実行可能ファイルパス（`cli.js`）を動的に解決している
   - bunのバーチャルファイルシステム（`/$bunfs/`）内ではこの解決が失敗する

2. **bunコンパイルの制約**
   - bunの`--compile`は全てのコードを単一バイナリに埋め込む
   - 動的なファイルパス解決やrequireが正常に動作しない可能性がある
   - Agent SDKのような複雑な外部依存関係のバンドルには不向き

### 試行した回避策

以下の対応も検討しましたが、いずれも根本的な解決には至りませんでした：

1. **`--external`オプション**
   - Agent SDKを外部依存として扱う
   - → スタンドアロンバイナリではなくなり、メリットが失われる

2. **esbuild事前バンドル + bunコンパイル**
   - esbuildでAgent SDKを含めてバンドルしてからbunでコンパイル
   - → Agent SDK内部のファイルシステムアクセスは依然として失敗する

3. **pathToClaudeCodeExecutableの明示的設定**
   - Agent SDKのオプションで実行可能ファイルパスを指定
   - → バーチャルファイルシステム内のパスでは動作しない

## Decision

**bunコンパイルによるバイナリ化を断念し、現在のesbuildによるJSバンドル方式を継続する。**

### 理由

1. **現状のパフォーマンスで十分**
   - esbuildによるバンドル（minify済み）は既に高速
   - Agent SDK起動のオーバーヘッドがボトルネックではない
   - 起動時間はユーザー体験に影響を与えるレベルではない

2. **実装の複雑性**
   - Agent SDKとの互換性問題の解決が困難
   - bunのバーチャルファイルシステムに依存する実装は保守が困難
   - 将来的なAgent SDKのアップデートで再び問題が発生する可能性

3. **代替案の欠如**
   - Node.js SEA（Single Executable Application）も同様の問題を抱える
   - Deno compileも検証が必要で、成功の保証がない

4. **開発効率の低下**
   - プラットフォーム別バイナリの管理コスト
   - CIでの複数プラットフォームビルドが必要
   - バイナリサイズが大きい（57MB）

## Consequences

### Positive

- ✅ 実装がシンプルで保守しやすい
- ✅ Agent SDKとの完全な互換性を維持
- ✅ プラットフォーム非依存（Node.jsがあれば動作）
- ✅ ビルド時間が短い（esbuildのみ）
- ✅ 配布サイズが小さい（22KB vs 57MB）

### Negative

- ❌ Node.js起動オーバーヘッドが残る（ただし体感できるレベルではない）
- ❌ node_modulesが必要（ただし、Lazy.nvimが自動管理）

### Neutral

- 開発モード（`dev_mode=true`）は引き続きサポート
  - bunで直接TypeScriptを実行
  - ビルド不要で開発効率が高い

## Alternatives Considered

### 1. Node.js SEA (Single Executable Application)

**検討内容:**

- Node.js v20+の公式機能
- `postject`を使用してバイナリにJSを埋め込む

**却下理由:**

- bunと同様にAgent SDKとの互換性問題が予想される
- 設定が複雑（manifest.json、署名など）
- bunより成熟度が低い

### 2. Deno compile

**検討内容:**

- Denoの`deno compile`コマンド
- TypeScript/JavaScript対応

**却下理由:**

- Agent SDKがDeno環境で動作するか未検証
- Node.js特有のAPIに依存している可能性
- 既存のNode.js環境を捨てるコストが高い

### 3. Esbuild + Stub実行ファイル

**検討内容:**

- esbuildでバンドル後、軽量なC/Rust製ランチャーでNode.jsを起動

**却下理由:**

- 複雑さに見合うメリットがない
- 現状のパフォーマンスで十分

## Implementation Notes

この決定に基づき、以下の変更を実施しました：

1. **削除した機能**
   - `node.use_binary`設定フィールド
   - `build.mjs`内のバイナリコンパイル処理
   - `command_builder.lua`のバイナリパス解決ロジック

2. **維持した機能**
   - esbuildによるJSバンドル（production mode）
   - bunによるTypeScript直接実行（development mode）
   - 既存のビルドプロセスとCI/CD

## Future Considerations

将来的に以下の状況が変化した場合、再検討の余地があります：

1. **Agent SDKの改善**
   - バイナリ化に対応した実装になる
   - 外部依存の動的解決を廃止

2. **bunの進化**
   - `--compile`時のファイルシステムエミュレーションが改善
   - 外部依存の扱いが柔軟になる

3. **パフォーマンス要求の変化**
   - 起動速度が実際の問題になる
   - ユーザーからの具体的な要望がある

## References

- [Bun Documentation: Bundler](https://bun.sh/docs/bundler)
- [Bun Documentation: Single-file executable](https://bun.sh/docs/bundler/executables)
- [Node.js SEA Documentation](https://nodejs.org/api/single-executable-applications.html)
- [@anthropic-ai/claude-agent-sdk](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk)

## Related ADRs

- ADR 003: Agent SDK vs CLI Comparison - Agent SDKを選択した理由
- ADR 006: Patch Storage JS Implementation - TypeScript/JavaScriptでの実装判断
