# AskUserQuestion 手動テスト手順

## 前提条件

1. vibing.nvimをNeovimにインストール済み
2. APIキーが設定済み

## テスト手順

### 1. Neovimでチャットを開く

```vim
:VibingChat
```

### 2. AskUserQuestionを促すプロンプトを送信

チャットバッファに以下のメッセージを入力して`<CR>`で送信:

```
I want to create a web application. Please use AskUserQuestion tool to ask me:
1. Which database to use (PostgreSQL, MySQL, or SQLite)
2. Which features I need (Authentication, Logging, Caching)
```

### 3. 期待される動作

Claudeが`AskUserQuestion`ツールを使用した場合、以下のような質問がチャットバッファに表示される:

```markdown
## Assistant

Which database should we use?

- PostgreSQL
- MySQL
- SQLite

Which features do you need?

- Authentication
- Logging
- Caching

質問に回答し終えたら`<CR>`で送信してください。
```

### 4. 回答方法

1. 不要な選択肢を削除（例: `dd`でMySQLとSQLiteを削除）
2. 残った選択肢:

```markdown
Which database should we use?

- PostgreSQL

Which features do you need?

- Authentication
- Logging
```

3. `<CR>`を押して送信

### 5. 期待される結果

- Claudeが選択された回答（PostgreSQL, Authentication, Logging）を受け取る
- それに基づいて会話が続く

## トラブルシューティング

### AskUserQuestionが使われない場合

Claudeが自発的にAskUserQuestionを使わないことがあります。以下を試してください:

1. より明示的なプロンプト:

   ```
   Please MUST use AskUserQuestion tool to ask me about database choice.
   Do not assume or guess - use the tool to ask.
   ```

2. Agent SDKのモードを確認:
   ```vim
   /mode plan
   ```
   Plan modeの方がAskUserQuestionを使いやすい傾向があります。

### デバッグ方法

1. ログ確認:

   ```bash
   # Agent Wrapperの出力を確認
   tail -f /tmp/vibing-debug.log
   ```

2. Lua側のデバッグ:
   ```vim
   :messages
   ```

## 実装確認ポイント

✅ `bin/agent-wrapper.mjs` - askFollowupQuestionコールバック実装済み
✅ `lua/vibing/infrastructure/adapter/agent_sdk.lua` - ask_user_questionイベント処理
✅ `lua/vibing/presentation/chat/buffer.lua` - 質問挿入と回答パース
✅ stdin/stdout通信経路が正しく設定されている

## 注意事項

- AskUserQuestionはClaudeが必要と判断した時のみ使用される
- 必ずしもすべてのリクエストで使われるわけではない
- 実装は正しく動作するが、Claudeの判断に依存する
