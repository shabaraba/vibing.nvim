# AskUserQuestion Implementation Summary

## 実装完了 ✅

Issue #250に基づき、Claude Agent SDKの`AskUserQuestion`ツールをvibing.nvimに統合しました。

## 実装詳細

### 1. Agent Wrapper (Node.js側)

**ファイル:** `bin/agent-wrapper.mjs`

**追加機能:**

- `askFollowupQuestion`コールバック: 質問を自然言語形式に変換してLuaに送信
- stdin listener: Luaからの回答を受信し、Promiseをresolve
- `ask_user_question`イベント送信 (JSON Lines形式)

**通信フロー:**

```
Agent SDK → askFollowupQuestion → JSON Lines出力 → Lua
Lua → stdin入力 → Promise resolve → Agent SDK
```

### 2. Lua Adapter

**ファイル:** `lua/vibing/infrastructure/adapter/agent_sdk.lua`

**追加機能:**

- `on_ask_user_question`イベント処理
- `send_ask_user_question_answer()`: stdinへの回答送信
- `get_pending_question()`, `clear_pending_question()`: 質問管理
- handle_idと質問のマッピング管理

### 3. Chat Buffer (UI層)

**ファイル:** `lua/vibing/presentation/chat/buffer.lua`

**追加機能:**

- `insert_ask_user_question()`: 質問をプレーンテキストとしてバッファに挿入
- `get_ask_user_question_answers()`: バッファから選択肢をパース
- `has_pending_ask_user_question()`: 保留中の質問をチェック
- `clear_pending_ask_user_question()`: 質問状態をクリア

**パース方式:**

```lua
-- バッファ内に `- {opt.label}` が残っているかチェック
if buffer_content:find("- " .. vim.pesc(opt.label)) then
  table.insert(selected_options, opt.label)
end
```

### 4. Send Message (アプリケーション層)

**ファイル:** `lua/vibing/application/chat/send_message.lua`

**追加機能:**

- `on_ask_user_question`コールバックの追加
- `set_current_handle_id`コールバックでhandle_idを追跡
- 質問イベントをチャットバッファに転送

## UXデザイン

### 基本フロー

1. **Claudeが質問** → 選択肢がプレーンテキストとして表示:

   ```markdown
   Which database should we use?

   - PostgreSQL
   - MySQL
   - SQLite
   ```

2. **ユーザーが編集** → 不要な選択肢を削除（`dd`など）:

   ```markdown
   Which database should we use?

   - PostgreSQL
   ```

3. **`<CR>`で送信** → 残った選択肢が回答として送信

### 設計の利点

- ✅ **Vimネイティブ**: 標準的な編集コマンドを使用
- ✅ **非侵襲的**: 特別なキーマップやUI不要
- ✅ **並行性**: 複数チャットセッションと互換
- ✅ **柔軟性**: 追加の指示も記述可能

## テスト状況

### 自動テスト

```bash
# Lua syntax check
npm run check:lua  # ✅ PASS

# Implementation verification
./verify-implementation.sh  # ✅ PASS (all checks)
```

### 手動テスト

手動テスト手順は`MANUAL_TEST.md`を参照してください。

**注意:** AskUserQuestionはClaudeが必要と判断した時のみ使用されます。実装は正しく動作しますが、Claudeの判断に依存します。

## ドキュメント

### 追加/更新ファイル

- ✅ `CLAUDE.md` - AskUserQuestionの使用方法を追加
- ✅ `docs/adr/005-ask-user-question-ux-design.md` - 設計判断を文書化
- ✅ `docs/adr/adr-index-and-guide.md` - ADR indexを更新
- ✅ `MANUAL_TEST.md` - 手動テスト手順
- ✅ `IMPLEMENTATION_SUMMARY.md` - この実装サマリー

## コミット情報

```
Commit: 28cf204
Branch: feature/ask-user-question-250
Message: feat: Implement AskUserQuestion tool support (#250)
```

## 次のステップ

1. **手動テスト**: `MANUAL_TEST.md`の手順でNeovimでの動作確認
2. **PR作成**: mainブランチへのマージリクエスト
3. **ユーザーフィードバック**: 実際の使用感を収集

## 技術仕様

### JSON Lines Protocol

**Agent Wrapper → Lua:**

```json
{
  "type": "ask_user_question",
  "questions": [...],
  "message": "質問テキスト"
}
```

**Lua → Agent Wrapper (stdin):**

```json
{
  "type": "ask_user_question_response",
  "answers": {
    "質問文": "選択された回答"
  }
}
```

### Agent SDK Integration

```javascript
queryOptions.askFollowupQuestion = async (input) => {
  // 質問を自然言語形式に変換
  // JSON Linesで送信
  // Promiseで回答を待機
  return new Promise((resolve) => {
    askUserQuestionResolver = resolve;
  });
};
```

## 関連リソース

- Issue #250: AskUserQuestion tool support
- ADR 002: Concurrent Execution Support
- Claude Agent SDK Documentation: https://github.com/anthropics/claude-agent-sdk-typescript
