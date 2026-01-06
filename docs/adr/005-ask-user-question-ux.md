# ADR 005: AskUserQuestion Tool UX Design

## Status

Proposed

## Date

2025-01-06

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

- 選択肢を各行に表示
- ユーザーは不要な行を`dd`で削除
- 残った選択肢が回答となる
- `<CR>`で確定

#### 操作フロー

**単一選択:**

1. 質問と選択肢が表示される
2. ユーザーは不要な選択肢を`dd`で削除
3. 残った1つの選択肢が回答
4. `<CR>`で確定

**複数選択:**

1. 質問と選択肢が表示される
2. ユーザーは不要な選択肢を`dd`で削除
3. 残った選択肢（複数可）が回答
4. `<CR>`で確定

#### 表示形式

**質問表示中:**

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 1/2: Database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which database should we use?

Delete unwanted options with dd, press <CR> to confirm

PostgreSQL
Relational, ACID compliant

MongoDB
Document-based, flexible schema

MySQL
Popular open-source relational database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**ユーザーが編集後（MongoDBとMySQLを削除）:**

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 1/2: Database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which database should we use?

Delete unwanted options with dd, press <CR> to confirm

PostgreSQL
Relational, ACID compliant
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

**確定後（履歴として残る）:**

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 1/2: Database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which database should we use?

✓ Selected: PostgreSQL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 実装方式

**選択肢の識別（Concealed text使用）:**

```lua
-- 選択肢の行にマーカーを埋め込む
"PostgreSQL<!--vibing:option:PostgreSQL-->"
"Relational, ACID compliant"
""
"MongoDB<!--vibing:option:MongoDB-->"
"Document-based, flexible schema"
```

HTMLコメントは`conceallevel=2`により非表示になる。

**キーマップ（最小限）:**

```lua
-- Enterで確定（残っている選択肢を収集）
vim.keymap.set('n', '<CR>', function()
  local selected_options = collect_remaining_options(buf)
  confirm_selection(selected_options)
end, { buffer = buf, nowait = true })

-- Escでキャンセル
vim.keymap.set('n', '<Esc>', cancel_question, { buffer = buf, nowait = true })
```

**選択肢の収集ロジック:**

```lua
local function collect_remaining_options(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local options = {}

  for _, line in ipairs(lines) do
    local option = line:match('<!--vibing:option:(.+)-->')
    if option then
      table.insert(options, option)
    end
  end

  return options
end
```

## Consequences

### Positive

- ✅ **キーマップの上書きが最小限**: `<CR>`と`<Esc>`のみ
- ✅ **完全にVimらしい**: `dd`, ビジュアルモード、コマンドなど全てが使える
- ✅ **実装が非常にシンプル**: 残っている選択肢を収集するだけ
- ✅ **単一選択も複数選択も同じ操作**: 残す行数が違うだけ
- ✅ **Undoで復元可能**: 操作ミスをすぐに修正できる
- ✅ **視覚的に直感的**: 残っている = 選択されている
- ✅ **学習コスト0**: Vimユーザーなら誰でもすぐに理解できる
- ✅ **複数インスタンス対応**: バッファごとに独立して動作

### Negative

- ⚠️ **誤って全削除の可能性**: 全選択肢を削除した場合のバリデーションが必要
- ⚠️ **説明文の扱い**: 選択肢と説明文を一緒に削除する必要がある（Concealed textで対応可能）
- ⚠️ **単一選択の強制**: 単一選択で複数残っている場合の警告が必要

### Risks and Mitigations

**Risk 1: ユーザーが全選択肢を削除してしまう**

- _Mitigation_: `<CR>`時に選択肢が0個なら警告を出す
- _Mitigation_: エラーメッセージで操作方法を説明

**Risk 2: 説明文だけ削除して選択肢が残る**

- _Mitigation_: Concealed textのマーカーで識別するため、表示文字列を編集しても問題なし

**Risk 3: 選択肢の文字列を編集してしまう**

- _Mitigation_: Concealed textのマーカーで識別するため、表示文字列を編集しても問題なし

## Alternatives Considered

### Alternative 1: Telescope/vim.ui.select ピッカー

**Rejected because:**

- グローバルUIのため、複数チャットインスタンスで競合する
- 他のチャットセッションの作業を中断してしまう
- どのチャットの質問か分からなくなる

### Alternative 2: 番号キー（1-4）による選択

**Rejected because:**

- ユーザーの通常のキーマップを上書きする
- 予期しない動作でユーザーが混乱する可能性
- 他のプラグインと競合する可能性

### Alternative 3: プレフィックスキー方式（gq1-4）

**Considered but not adopted because:**

- 追加のキーマップを覚える必要がある
- 方式Eの方がよりシンプルで自然

### Alternative 4: カーソル移動 + Enter方式

**Considered but not adopted because:**

- `<CR>`, `<Space>` などのキーマップを上書きする必要がある
- 複数選択時の実装が複雑
- 方式Eの方がよりシンプルで自然

### Alternative 5: Insertモード入力方式

**Rejected because:**

- モード切り替えが必要で操作が冗長
- Vimらしくない

## Implementation Plan

### Phase 1: 基本実装（MVP）

1. `lua/vibing/ui/ask_user_question.lua` 作成
2. 質問セクションのレンダリング
3. 選択肢のConcealed text埋め込み
4. 残っている選択肢の収集ロジック
5. `<CR>`と`<Esc>`のキーマップ設定

### Phase 2: Agent SDK統合

1. bin/agent-wrapper.mjsでのAskUserQuestion処理
2. canUseToolコールバックでの回答返却
3. チャットバッファへの質問挿入

### Phase 3: エラーハンドリング

1. 全削除時のバリデーション
2. 単一選択で複数残っている場合の警告
3. キャンセル時の処理

### Phase 4: UX改善

1. 回答確定後の表示整形
2. 複数質問の順次処理
3. "Other"オプション対応（vim.ui.input）

## References

- Issue #250: AskUserQuestion ツールのチャットバッファ対応
- [Agent SDK TypeScript Reference](https://platform.claude.com/docs/en/agent-sdk/typescript)
- [Handling Permissions - Claude Docs](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [Claude Agent SDK | Promptfoo](https://www.promptfoo.dev/docs/providers/claude-agent-sdk/)

## Notes

この設計の核心は「Vim上なんだから」という発想。特別なキーマップを追加するのではなく、Vimの標準的な編集操作（`dd`, `d2d`, ビジュアルモードでの削除など）をそのまま活用することで、学習コスト0で直感的なUXを実現する。
