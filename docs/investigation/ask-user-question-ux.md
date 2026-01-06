# AskUserQuestion Tool UX Investigation (改訂版)

## 調査日

2025-01-06

## 調査目的

Issue #250: Claude Agent SDKの`AskUserQuestion`ツールをvibing.nvimのチャットバッファで扱う際の、Neovimとして馴染む良いUXを提案する。

## Claude Agent SDKの`AskUserQuestion`について

### 概要

`AskUserQuestion`は、Claude Codeがコード生成中にユーザーに対して選択肢付きの質問を投げかけることができるツールです。
推測や仮定をする代わりに、ユーザーに明確な選択を促すことができます。

参考:

- [Agent SDK TypeScript Reference](https://platform.claude.com/docs/en/agent-sdk/typescript)
- [Handling Permissions - Claude Docs](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [Claude Agent SDK | Promptfoo](https://www.promptfoo.dev/docs/providers/claude-agent-sdk/)

### ツールの構造

#### 入力スキーマ

```typescript
interface AskUserQuestionInput {
  questions: Question[]; // 1-4個の質問
}

interface Question {
  question: string; // 質問文（明確で完結している必要がある）
  header: string; // 短いラベル（最大12文字）例: "Database", "Features"
  options: Option[]; // 2-4個の選択肢
  multiSelect: boolean; // 複数選択を許可するか
}

interface Option {
  label: string; // 選択肢のラベル（1-5単語）
  description: string; // 選択肢の説明（トレードオフや含意を説明）
}
```

#### 回答の返し方

```typescript
canUseTool: async (toolName, input) => {
  if (toolName === 'AskUserQuestion') {
    const answers = await collectUserAnswers(input.questions);

    return {
      behavior: 'allow',
      updatedInput: {
        questions: input.questions, // 元の質問をパススルー（必須）
        answers: {
          'Which database should we use?': 'PostgreSQL',
          'Which features should we enable?': 'Authentication, Logging', // 複数選択はカンマ区切り
        },
      },
    };
  }
  return { behavior: 'allow', updatedInput: input };
};
```

### 重要なポイント

1. **質問は1-4個**: 一度に複数の質問を投げかけることができる
2. **回答形式**: `Record<question: string, answer: string>`
   - 単一選択: ラベル文字列（例: `"PostgreSQL"`）
   - 複数選択: カンマ区切り文字列（例: `"Auth, Logging"`）
3. **パススルー**: `questions`配列は必ず`updatedInput`に含める
4. **"Other"オプション**: 自動で追加され、カスタムテキスト入力が可能

## 制約条件: 複数インスタンス問題

### 問題

vibing.nvimは一つのNeovimセッション内で複数のチャットバッファが同時に動作することがある。
この場合、Telescopeやfzf-luaなどのグローバルなピッカーを使うと：

- ❌ 別のチャットセッションの作業を中断してしまう
- ❌ どのチャットの質問か分からなくなる
- ❌ ユーザーが混乱する

### 必要な要件

- ✅ **チャットバッファごとに独立**: 各チャットのコンテキストを保つ
- ✅ **非侵襲的**: 他のチャットやウィンドウに影響しない
- ✅ **コンテキストが明確**: どのチャットの質問か一目で分かる

## 提案: AskUserQuestion UX設計

### 設計方針

1. **チャットバッファ内での完結**:
   - グローバルなピッカー（Telescope等）は**使わない**
   - チャットバッファに質問を挿入し、その場で選択
   - 各チャットセッションが独立して動作

2. **インラインな選択UI**:
   - 質問をチャットバッファに挿入
   - 番号キー（1-4）で選択
   - 複数質問は順次表示

3. **視覚的な分離**:
   - 質問セクションを明確にマーク
   - 選択可能な状態を視覚的に示す
   - 回答後は履歴として残す

### 実装案

#### 1. UIフロー

```
Claude質問 → バッファに挿入 → 番号キー入力待ち → 選択 → 回答記録 → SDK返答
```

#### 2. チャットバッファでの表示形式

##### 質問表示中（選択可能状態）

```markdown
## Assistant

データベースの選択が必要です。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 1/2: Database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which database should we use?

1. PostgreSQL
   → Relational, ACID compliant

2. MongoDB
   → Document-based, flexible schema

3. MySQL
   → Popular open-source relational database

4. Other (custom input)

Press 1-4 to select, or <Esc> to cancel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

##### 回答後（履歴として残る）

```markdown
## Assistant

データベースの選択が必要です。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 1/2: Database
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which database should we use?

✓ Selected: PostgreSQL
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

では、PostgreSQLを使って実装します...
```

##### 複数選択の場合

```markdown
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 Question 2/2: Features (Multi-select)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Which features should we enable?

1. [x] Authentication
       → User login and sessions

2. [ ] Caching
       → Redis-based response caching

3. [x] Logging
       → Request and error logging

4. [ ] Monitoring
       → Application metrics and health checks

Press 1-4 to toggle, <Enter> to confirm, <Esc> to cancel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

#### 3. 実装の詳細

##### キーマッピング（質問表示中のみ有効）

```lua
-- 単一選択モード
vim.keymap.set('n', '1', select_option(1), { buffer = buf, nowait = true })
vim.keymap.set('n', '2', select_option(2), { buffer = buf, nowait = true })
vim.keymap.set('n', '3', select_option(3), { buffer = buf, nowait = true })
vim.keymap.set('n', '4', select_option(4), { buffer = buf, nowait = true })
vim.keymap.set('n', '<Esc>', cancel_question, { buffer = buf, nowait = true })

-- 複数選択モード
vim.keymap.set('n', '1', toggle_option(1), { buffer = buf, nowait = true })
vim.keymap.set('n', '2', toggle_option(2), { buffer = buf, nowait = true })
vim.keymap.set('n', '3', toggle_option(3), { buffer = buf, nowait = true })
vim.keymap.set('n', '4', toggle_option(4), { buffer = buf, nowait = true })
vim.keymap.set('n', '<CR>', confirm_selection, { buffer = buf, nowait = true })
vim.keymap.set('n', '<Esc>', cancel_question, { buffer = buf, nowait = true })
```

##### モジュール構造

```
lua/vibing/ui/ask_user_question.lua
  - show_inline_question(chat_buffer, question, question_index, total_questions)
    - チャットバッファに質問を挿入
    - 一時的なキーマップを設定
    - 選択を待機（コルーチン）
    - 選択後、キーマップを解除
    - 回答を返す

  - _render_question(question, question_index, total_questions)
    - 質問をMarkdown形式で整形
    - 選択肢を番号付きリストで表示

  - _render_answer(question, answer)
    - 回答を整形してバッファに挿入

  - _setup_keymaps(chat_buffer, question, callback)
    - 質問タイプに応じたキーマップを設定

  - _cleanup_keymaps(chat_buffer)
    - 一時的なキーマップを削除
```

##### Agent SDK統合

```lua
-- lua/vibing/infrastructure/adapter/agent_sdk.lua

local function handle_ask_user_question(input, chat_buffer)
  local AskUserQuestion = require("vibing.ui.ask_user_question")
  local answers = {}

  -- 各質問を順次処理
  for i, question in ipairs(input.questions) do
    local answer = AskUserQuestion.show_inline_question(
      chat_buffer,
      question,
      i,
      #input.questions
    )

    if not answer then
      -- キャンセルされた
      return {
        behavior = "deny",
        message = "User cancelled the question"
      }
    end

    answers[question.question] = answer
  end

  return {
    behavior = "allow",
    updatedInput = {
      questions = input.questions,
      answers = answers
    }
  }
end
```

#### 4. 状態管理

質問表示中は特別な状態になる:

```lua
local QuestionState = {
  active = false,           -- 質問表示中か
  chat_buffer = nil,        -- 対象チャットバッファ
  question = nil,           -- 現在の質問
  selected_options = {},    -- 複数選択時の選択状態
  callback = nil,           -- 選択完了時のコールバック
}
```

### UXの特徴

#### ✅ 良い点

1. **チャットごとに独立**: 他のチャットに影響しない
2. **コンテキストが明確**: 質問がどのチャットのものか一目瞭然
3. **履歴が残る**: 質問と回答がチャットログに記録される
4. **シンプル**: 番号キーを押すだけ
5. **中断可能**: `<Esc>`でキャンセル可能
6. **Neovimネイティブ**: 外部UIに依存しない

#### ⚠️ 検討事項

1. **一時的なキーマップ**: 通常のキーマップを上書きする（質問中のみ）
2. **複数質問の処理**: 順次表示（一問ずつ）
3. **視覚的フィードバック**: バッファ更新で選択状態を表示

### 代替案との比較

| アプローチ                       | メリット                                                         | デメリット                                   |
| -------------------------------- | ---------------------------------------------------------------- | -------------------------------------------- |
| **提案: インラインバッファ選択** | ・独立動作<br>・コンテキスト明確<br>・履歴が自然<br>・外部UI不要 | ・キーマップ一時上書き<br>・実装コスト中程度 |
| vim.ui.select                    | ・標準API<br>・実装簡単                                          | ・グローバルUI<br>・複数インスタンスで競合   |
| Telescopeピッカー                | ・見た目が良い<br>・ファジー検索                                 | ・グローバルUI<br>・複数インスタンスで競合   |
| フローティングウィンドウ         | ・モーダルUI<br>・一括表示可能                                   | ・コンテキスト不明瞭<br>・実装コスト高       |

## 実装ロードマップ

### Phase 1: 基本実装（MVP）

1. `lua/vibing/ui/ask_user_question.lua`作成
2. 単一選択の番号キー対応
3. チャットバッファへの質問挿入
4. Agent SDKとの統合

### Phase 2: 機能拡張

1. 複数選択対応（トグル + Enter確認）
2. "Other"オプション対応（vim.ui.input）
3. エラーハンドリング強化

### Phase 3: UX改善

1. 選択状態のリアルタイム更新（複数選択時）
2. アニメーション効果（オプション）
3. カスタマイズ可能な装飾

### Phase 4: テストとドキュメント

1. ユニットテスト追加
2. 統合テスト（Agent SDK連携）
3. ユーザードキュメント作成

## 参考資料

- [Agent SDK TypeScript Reference](https://platform.claude.com/docs/en/agent-sdk/typescript)
- [Handling Permissions - Claude Docs](https://platform.claude.com/docs/en/agent-sdk/permissions)
- [Claude Agent SDK | Promptfoo](https://www.promptfoo.dev/docs/providers/claude-agent-sdk/)
- [What is Claude Code's AskUserQuestion tool?](https://www.atcyrus.com/stories/claude-code-ask-user-question-tool-guide)

## まとめ

`AskUserQuestion`ツールのNeovim UXとして、**チャットバッファ内インライン選択**のアプローチを提案します。

この設計は：

1. ✅ **複数インスタンス対応**: 各チャットが独立して動作
2. ✅ **コンテキスト保持**: 質問がどのチャットのものか明確
3. ✅ **シンプルな操作**: 番号キーを押すだけ
4. ✅ **履歴として残る**: チャットログに質問と回答が記録
5. ✅ **外部依存なし**: Neovimの基本機能のみで実装

Telescopeやvim.ui.selectなどのグローバルUIは使わず、チャットバッファ内で完結させることで、
複数のvibing.nvimインスタンスが同時に動作しても問題なく動作します。
