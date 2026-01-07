# ADR 005: AskUserQuestion Tool UX Design

## Status

Accepted

## Date

2025-01-07

## Context

Issue #250: Claude Agent SDKの`AskUserQuestion`ツールをvibing.nvimのチャットバッファで扱う際のUXを設計する必要がある。

### AskUserQuestion ツールとは

Claude Agent SDKの`AskUserQuestion`は、Claude Codeがコード生成中にユーザーに対して選択肢付きの質問を投げかけることができるツール。推測や仮定をする代わりに、ユーザーに明確な選択を促すことができる。

**入力スキーマ:**

```typescript
interface AskUserQuestionInput {
  questions: Question[]; // 1-4個の質問
}

interface Question {
  question: string; // 質問文
  header: string; // 短いラベル（最大12文字）
  options: Option[]; // 2-4個の選択肢
  multiSelect: boolean; // 複数選択を許可するか
}

interface Option {
  label: string; // 選択肢のラベル
  description: string; // 選択肢の説明
}
```

**回答形式:**

```typescript
{
  questions: input.questions,  // 元の質問をパススルー（必須）
  answers: {
    "Which database should we use?": "PostgreSQL",  // 単一選択
    "Which features?": "Auth, Logging"  // 複数選択はカンマ区切り
  }
}
```

### 制約条件

1. **複数インスタンス問題**: vibing.nvimは一つのNeovimセッション内で複数のチャットバッファが同時に動作する可能性がある
2. **グローバルUIの問題**: Telescopeやvim.ui.selectなどのグローバルなピッカーを使うと、他のチャットセッションを妨害する
3. **キーマップの侵襲性**: 一時的なキーマップの上書きはユーザーの通常操作を妨げる可能性がある

## Decision

### 採用: 方式E（行削除による選択）

**Vimの標準的な編集操作をそのまま活用する方式を採用する。**

#### 基本コンセプト

Assistantが質問を提示する際、選択可能な項目をプレーンテキストとして配置する。ユーザーは不要な選択肢を**行削除**（`dd`など）で削除し、最終的に残った選択肢を採用する。

#### 実装アーキテクチャ

**1. Agent Wrapperでのメッセージ変換（サーバー側）**

`AskUserQuestion`ツールが呼ばれた際、Agent Wrapperは質問内容を自然言語形式でチャットバッファに送信する。

- `ask_user_question`イベントをJSON Lines形式で送信
- ユーザーの回答をstdin経由で受信するPromiseを生成

**2. Luaでのバッファ編集と回答パース（クライアント側）**

- `ChatBuffer:insert_ask_user_question()` - 質問をバッファに挿入
- ユーザーが`<CR>`送信時、`ChatBuffer:get_ask_user_question_answers()`で回答をパース
- バッファ内容から残っている`- {opt.label}`をチェックして選択を判定

**3. Agent Wrapperでの回答受信とSDK応答（サーバー側）**

Luaから`ask_user_question_response`イベントを受信し、保留中のPromiseをresolveしてClaude SDKに返す。

## Rationale

### 選択理由

- **Vimの標準的な操作のみ**: ユーザーは新しい操作を学ぶ必要がなく、既知の編集コマンド（`dd`など）を使用
- **柔軟性**: 質問に対して追加の指示や自由記述も可能
- **非侵襲的**: 一時的なキーマップや外部UIを使用しないため、他のチャットセッションに影響しない
- **実装の簡潔性**: バッファの内容をパースするだけで回答を取得できる

### Rejected Alternatives

- **Telescope.nvim統合**: グローバルUIで複数セッションと干渉
- **一時的なキーマップ**: 他のバッファやユーザー操作と競合
- **自然言語回答**: LLMパースに依存し精度が不安定
- **インラインメニュー**: 実装が複雑で既存UIと干渉

## Consequences

### Positive

- シンプルな実装（バッファパースとメッセージ送信のみ）
- vibing.nvimの既存ワークフロー（バッファ編集→`<CR>`送信）と整合
- 低侵襲性（グローバルUIやキーマップを使わない）

### Negative

- ユーザーの学習コスト（ドキュメントで説明が必要）
- パース精度（ユーザーがフォーマットを壊した場合の対策が必要）

## Implementation

実装は以下のファイルで行われた:

- `bin/agent-wrapper.mjs` - AskUserQuestionコールバックとstdin処理
- `lua/vibing/infrastructure/adapter/agent_sdk.lua` - ask_user_questionイベント処理
- `lua/vibing/presentation/chat/buffer.lua` - 質問挿入と回答パース
- `lua/vibing/application/chat/send_message.lua` - handle_id管理とコールバック追加

## References

- Issue #250: AskUserQuestion tool support
- Claude Agent SDK documentation
- ADR 002: Concurrent Execution Support
