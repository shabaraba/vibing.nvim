# E2Eテストケース: MCPサーバー/RPC機能

## テストID

`E2E-MCP-001`

## テスト対象

RPC サーバーの起動、通信、各種ハンドラーの動作

## 前提条件

- Neovimが起動している
- vibing.nvimプラグインがインストールされている
- `mcp.enabled = true` が設定されている
- Node.jsがインストールされている（MCPクライアント用）

## テスト手順

### 1. RPCサーバーの起動

**操作:**

```vim
:lua require("vibing").setup({ mcp = { enabled = true, rpc_port = 9876 } })
```

**期待される動作:**

- RPCサーバーが `127.0.0.1:9876` で起動する
- ポートが使用中の場合は9877-9885で自動的に次のポートを試行する
- 起動成功メッセージが表示される

**検証ポイント:**

```bash
# ポートがリスニング状態であることを確認
lsof -i :9876
# または
netstat -an | grep 9876

# 期待される出力:
# nvim [PID] ... TCP 127.0.0.1:9876 (LISTEN)
```

```lua
-- Luaから確認
local server = require("vibing.infrastructure.rpc.server")
local port = server.get_current_port()
assert(port >= 9876 and port <= 9885)
```

### 2. RPC レジストリファイルの作成

**期待される動作:**

- `.vibing/rpc-registry.json` ファイルが作成される
- ファイルには現在のNeovimインスタンスのポート情報が記録される

**検証ポイント:**

```bash
cat .vibing/rpc-registry.json
# 期待される内容:
# {
#   "instances": {
#     "[nvim-instance-id]": {
#       "port": 9876,
#       "pid": [process-id],
#       "timestamp": "[ISO8601]"
#     }
#   }
# }
```

### 3. バッファ操作ハンドラー

#### 3.1 buf_get_lines

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "buf_get_lines",
  "params": {
    "bufnr": 1,
    "start": 0,
    "end": -1
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "lines": ["line 1", "line 2", "..."]
  }
}
```

#### 3.2 buf_set_lines

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "buf_set_lines",
  "params": {
    "bufnr": 1,
    "start": 0,
    "end": 1,
    "lines": ["new line 1"]
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "result": {
    "success": true
  }
}
```

**検証ポイント:**

```lua
-- バッファの内容が変更されていることを確認
local lines = vim.api.nvim_buf_get_lines(1, 0, -1, false)
assert(lines[1] == "new line 1")
```

#### 3.3 list_buffers

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "list_buffers",
  "params": {}
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "buffers": [
      {
        "bufnr": 1,
        "name": "/path/to/file.txt",
        "loaded": true,
        "listed": true,
        "modified": false
      }
    ]
  }
}
```

### 4. カーソル操作ハンドラー

#### 4.1 get_cursor_position

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "get_cursor_position",
  "params": {
    "winnr": 1000
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 4,
  "result": {
    "row": 1,
    "col": 0
  }
}
```

#### 4.2 set_cursor_position

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "set_cursor_position",
  "params": {
    "winnr": 1000,
    "row": 10,
    "col": 5
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 5,
  "result": {
    "success": true
  }
}
```

**検証ポイント:**

```lua
-- カーソル位置が変更されていることを確認
local pos = vim.api.nvim_win_get_cursor(1000)
assert(pos[1] == 10)
assert(pos[2] == 5)
```

### 5. LSP操作ハンドラー

#### 5.1 lsp_definition

**前提条件:**

- LSPサーバーがアタッチされているバッファがある
- 定義が存在するシンボルにカーソルがある

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "lsp_definition",
  "params": {
    "bufnr": 1,
    "line": 5,
    "col": 10
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 6,
  "result": {
    "locations": [
      {
        "uri": "file:///path/to/file.lua",
        "range": {
          "start": { "line": 1, "character": 0 },
          "end": { "line": 1, "character": 10 }
        }
      }
    ]
  }
}
```

#### 5.2 lsp_references

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "lsp_references",
  "params": {
    "bufnr": 1,
    "line": 5,
    "col": 10
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 7,
  "result": {
    "locations": [
      {
        "uri": "file:///path/to/file.lua",
        "range": {
          "start": { "line": 10, "character": 5 },
          "end": { "line": 10, "character": 15 }
        }
      }
    ]
  }
}
```

#### 5.3 lsp_hover

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "lsp_hover",
  "params": {
    "bufnr": 1,
    "line": 5,
    "col": 10
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 8,
  "result": {
    "contents": "function name(param1: string): void\n\nDescription of the function."
  }
}
```

### 6. ウィンドウ操作ハンドラー

#### 6.1 list_windows

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "list_windows",
  "params": {}
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 9,
  "result": {
    "windows": [
      {
        "winnr": 1000,
        "bufnr": 1,
        "width": 80,
        "height": 24
      }
    ]
  }
}
```

#### 6.2 get_window_info

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "get_window_info",
  "params": {
    "winnr": 1000
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": {
    "winnr": 1000,
    "bufnr": 1,
    "width": 80,
    "height": 24,
    "col": 0,
    "row": 0
  }
}
```

### 7. 実行ハンドラー

#### 7.1 execute (シェルコマンド)

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "execute",
  "params": {
    "command": "echo 'Hello from RPC'"
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "output": "Hello from RPC\n",
    "exit_code": 0
  }
}
```

### 8. メッセージ送信ハンドラー

#### 8.1 send_message

**前提条件:**

- チャットバッファが開いている

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "send_message",
  "params": {
    "message": "RPCからのメッセージ"
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": {
    "success": true
  }
}
```

**検証ポイント:**

```lua
-- チャットバッファにメッセージが追加されていることを確認
```

## 異常系テスト

### 9. 無効なJSON

**RPC リクエスト:**

```
invalid json {{{
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32700,
    "message": "Parse error"
  }
}
```

### 10. 存在しないメソッド

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "non_existent_method",
  "params": {}
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "error": {
    "code": -32601,
    "message": "Method not found"
  }
}
```

### 11. LSPタイムアウト

**前提条件:**

- LSPサーバーが応答しない状態

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 14,
  "method": "lsp_definition",
  "params": {
    "bufnr": 1,
    "line": 5,
    "col": 10
  }
}
```

**期待される動作:**

- 15秒後にタイムアウト
- 空のレスポンスまたはエラーが返される

### 12. 無効なバッファ番号

**RPC リクエスト:**

```json
{
  "jsonrpc": "2.0",
  "id": 15,
  "method": "buf_get_lines",
  "params": {
    "bufnr": 99999,
    "start": 0,
    "end": -1
  }
}
```

**期待されるレスポンス:**

```json
{
  "jsonrpc": "2.0",
  "id": 15,
  "error": {
    "code": -32602,
    "message": "Invalid buffer number"
  }
}
```

## パフォーマンステスト

### 13. 大量のリクエスト

**操作:**

```bash
# 100個のリクエストを連続で送信
for i in {1..100}; do
  echo '{"jsonrpc":"2.0","id":'$i',"method":"list_buffers","params":{}}' | nc localhost 9876
done
```

**期待される動作:**

- すべてのリクエストに応答が返される
- Neovimがフリーズしない
- メモリリークがない

## クリーンアップ

**操作:**

```vim
:lua require("vibing.infrastructure.rpc.server").stop()
```

**期待される動作:**

- RPCサーバーが停止する
- ポートがクローズされる
- レジストリファイルから該当エントリが削除される

## 成功基準

- [ ] RPCサーバーが正しく起動する
- [ ] レジストリファイルが正しく管理される
- [ ] 全てのハンドラーが正しく動作する
- [ ] エラーハンドリングが適切に機能する
- [ ] タイムアウト処理が正しく動作する
- [ ] パフォーマンスが許容範囲内
- [ ] サーバーのクリーンアップが正しく動作する

## 関連ファイル

- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/server.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/init.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/buffer.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/cursor.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/lsp.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/window.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/execute.lua`
- `/Users/shaba/workspace/nvim-plugins/vibing.nvim/lua/vibing/infrastructure/rpc/handlers/message.lua`
