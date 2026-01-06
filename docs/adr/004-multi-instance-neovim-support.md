# ADR 004: Multi-Instance Neovim Support for MCP Integration

## Status

Accepted

## Context

vibing.nvimのMCP統合において、複数のNeovimインスタンスを同時に起動すると、最初に起動したインスタンスに対してしか操作できないという問題がありました（Issue #212）。

### 問題の詳細

従来の実装では以下の制約がありました：

1. **固定ポート問題**: すべてのNeovimインスタンスが同じRPCサーバーポート（9876）にバインドしようとする
2. **ポート競合**: 2つ目以降のインスタンスは`EADDRINUSE`エラーでRPCサーバーの起動に失敗
3. **単一接続**: MCPサーバーは固定ポート（9876）にのみ接続するため、最初のインスタンスにしか到達できない
4. **インスタンス発見不可**: 実行中のインスタンスを発見・識別する仕組みが存在しない

### アーキテクチャ図（変更前）

```text
┌─────────────────────────────────────────────────────────────────┐
│ Neovim Instance 1                                                │
│  └─ RPC Server (port 9876) ✅                                    │
│      └─ Accepts connections                                      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Neovim Instance 2                                                │
│  └─ RPC Server (port 9876) ❌                                    │
│      └─ Bind fails: EADDRINUSE                                   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Claude Code Process                                              │
│  └─ MCP Server                                                   │
│      └─ TCP Client → 127.0.0.1:9876 (fixed)                     │
│          └─ Only reaches Instance 1 ❌                           │
└─────────────────────────────────────────────────────────────────┘
```

## Decision

マルチインスタンス対応のために、以下の設計変更を実装しました：

### 1. 動的ポート割り当て（Lua側）

**実装**: `lua/vibing/infrastructure/rpc/server.lua`

- RPCサーバーは9876-9885の範囲でポートを順次試行
- 最初に利用可能なポートを使用
- 最大10インスタンスまで同時実行可能

```lua
function M.start(base_port)
  base_port = base_port or 9876
  local max_attempts = 10

  -- Try ports from base_port to base_port+9
  for i = 0, max_attempts - 1 do
    local try_port = base_port + i

    -- Skip if port is already in use by another instance
    if registry.is_port_in_use(try_port) then
      goto continue
    end

    server = uv.new_tcp()
    local bind_ok, bind_err = server:bind("127.0.0.1", try_port)

    if bind_ok then
      local listen_ok, listen_err = server:listen(128, function(err)
        -- ... connection handler ...
      end)

      if listen_ok then
        successful_port = try_port
        current_port = try_port
        break
      end
    end

    ::continue::
  end

  -- Register instance in registry
  registry.register(successful_port)

  return successful_port
end
```

### 2. インスタンスレジストリ（Lua側）

**実装**: `lua/vibing/infrastructure/rpc/registry.lua`

- 各インスタンスの情報をJSONファイルとして保存
- レジストリの場所: `vim.fn.stdpath("data")/vibing-instances/`
  - Linux/macOS: `~/.local/share/nvim/vibing-instances/`
  - Windows: `%LOCALAPPDATA%\nvim-data\vibing-instances\`
- ファイル名: `{pid}.json`
- 保存内容: PID、ポート番号、作業ディレクトリ、起動時刻

```lua
-- レジストリエントリの例
{
  "pid": 12345,
  "port": 9877,
  "cwd": "/home/user/project",
  "started_at": 1704470400
}
```

**機能**:

- `register(port)`: 現在のインスタンスを登録
- `unregister()`: インスタンス終了時にレジストリから削除
- `is_port_in_use(port)`: 他のインスタンスがポートを使用中か確認

### 3. マルチポートソケット管理（TypeScript側）

**実装**: `mcp-server/src/rpc.ts`

- ポートごとに独立したソケットを管理
- `Map<port, Socket>`でソケットプールを実装
- ポートごとに独立した pending requests と buffer を管理

```typescript
// Multi-port support: Map of port -> socket
const sockets = new Map<number, net.Socket>();

// Multi-port support: Map of port -> (request_id -> pending)
const pendingRequests = new Map<
  number,
  Map<
    number,
    {
      resolve: (value: any) => void;
      reject: (error: Error) => void;
    }
  >
>();

// Multi-port support: Map of port -> buffer
const buffers = new Map<number, string>();

function getSocket(port: number): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const existingSocket = sockets.get(port);
    if (existingSocket && !existingSocket.destroyed) {
      resolve(existingSocket);
      return;
    }

    // Create new socket and store in pool
    const socket = new net.Socket();
    // ... socket setup ...
    socket.connect(port, '127.0.0.1', () => {
      sockets.set(port, socket);
      resolve(socket);
    });
  });
}

export async function callNeovim(method: string, params: any = {}, port?: number): Promise<any> {
  const targetPort = port !== undefined ? port : NVIM_RPC_PORT;
  const sock = await getSocket(targetPort);
  // ... send JSON-RPC request ...
}
```

### 4. MCPツールの拡張

**実装**:

- `mcp-server/src/tools/common.ts` - 共通の`rpc_port`パラメータ定義
- `mcp-server/src/tools/*.ts` - 全ツールに`rpc_port`パラメータを追加
- `mcp-server/src/handlers/*.ts` - ハンドラーで`rpc_port`を`callNeovim()`に渡す

**新規ツール**: `nvim_list_instances` - 実行中のインスタンス一覧を取得

```typescript
// All tools now accept optional rpc_port parameter
export const bufferTools = [
  {
    name: 'nvim_get_buffer',
    description: 'Get current buffer content',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      }),
    },
  },
  // ... other tools
];
```

### 5. インスタンス発見とクリーンアップ（TypeScript側）

**実装**: `mcp-server/src/handlers/instances.ts`

- レジストリディレクトリから全JSONファイルを読み取り
- `process.kill(pid, 0)`でプロセスの生存確認（シグナル0は存在チェック）
- 死んだプロセスのレジストリファイルは自動削除
- レース条件対策: ファイル削除時の`ENOENT`エラーを無視

```typescript
export async function handleListInstances(args: any) {
  const registryPath = getRegistryPath();
  const files = await fs.readdir(registryPath);
  const instances = [];

  for (const file of files) {
    if (!file.endsWith('.json')) continue;

    const filePath = path.join(registryPath, file);
    const content = await fs.readFile(filePath, 'utf-8');
    const data = JSON.parse(content);

    if (data && data.pid) {
      try {
        process.kill(data.pid, 0); // Signal 0: existence check
        instances.push(data);
      } catch (e) {
        // Process is dead, clean up stale registry file
        try {
          await fs.access(filePath);
          await fs.unlink(filePath);
        } catch (unlinkErr) {
          // File already deleted or permission denied - ignore
        }
      }
    }
  }

  instances.sort((a, b) => (b.started_at || 0) - (a.started_at || 0));
  return { content: [{ type: 'text', text: JSON.stringify({ instances }, null, 2) }] };
}
```

### アーキテクチャ図（変更後）

```text
┌─────────────────────────────────────────────────────────────────┐
│ Neovim Instance 1 (PID: 1234)                                    │
│  ├─ RPC Server (port 9876) ✅                                    │
│  └─ Registry: ~/.local/share/nvim/vibing-instances/1234.json    │
│      └─ { pid: 1234, port: 9876, cwd: "/proj1", started_at: … } │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Neovim Instance 2 (PID: 5678)                                    │
│  ├─ RPC Server (port 9877) ✅                                    │
│  └─ Registry: ~/.local/share/nvim/vibing-instances/5678.json    │
│      └─ { pid: 5678, port: 9877, cwd: "/proj2", started_at: … } │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Neovim Instance 3 (PID: 9012)                                    │
│  ├─ RPC Server (port 9878) ✅                                    │
│  └─ Registry: ~/.local/share/nvim/vibing-instances/9012.json    │
│      └─ { pid: 9012, port: 9878, cwd: "/proj3", started_at: … } │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Claude Code Process                                              │
│  └─ MCP Server                                                   │
│      ├─ Socket Pool:                                             │
│      │   ├─ socket[9876] → Instance 1 ✅                         │
│      │   ├─ socket[9877] → Instance 2 ✅                         │
│      │   └─ socket[9878] → Instance 3 ✅                         │
│      │                                                            │
│      └─ MCP Tools:                                               │
│          ├─ nvim_list_instances() → reads registry              │
│          └─ nvim_get_buffer({ rpc_port: 9877 }) → Instance 2    │
└─────────────────────────────────────────────────────────────────┘
```

## Consequences

### 利点

1. **マルチインスタンス対応**: 最大10個のNeovimインスタンスを同時に操作可能
2. **自動ポート割り当て**: ユーザーはポート番号を意識する必要がない
3. **インスタンス発見**: `nvim_list_instances`で実行中のインスタンスを検出可能
4. **後方互換性**: 既存の設定はそのまま動作（デフォルトポート9876）
5. **自動クリーンアップ**: 死んだプロセスのレジストリは自動削除
6. **プラットフォーム対応**: Linux/macOS/Windows で正しくレジストリパスを解決

### 制約

1. **インスタンス数上限**: 最大10インスタンス（ポート範囲9876-9885）
2. **手動ポート指定**: ユーザーはどのインスタンスに接続するか明示的に指定する必要がある
3. **レジストリクリーンアップタイミング**: `nvim_list_instances`呼び出し時にのみクリーンアップ実行

### 将来の拡張可能性

1. **自動インスタンス選択**: 作業ディレクトリ（CWD）に基づいた自動選択
2. **インスタンスラベリング**: ユーザー定義のラベル・名前の付与
3. **フォーカスインスタンス取得**: 現在フォーカスされているNeovimを検出
4. **カスタムポート範囲**: 設定でポート範囲をカスタマイズ可能に
5. **レジストリキャッシング**: パフォーマンス向上のためのキャッシュ機構

## 実装ファイル

### Lua (Neovim側)

- `lua/vibing/infrastructure/rpc/server.lua` - 動的ポート割り当て
- `lua/vibing/infrastructure/rpc/registry.lua` - インスタンスレジストリ管理

### TypeScript (MCP Server側)

- `mcp-server/src/rpc.ts` - マルチポートソケット管理
- `mcp-server/src/tools/common.ts` - 共通`rpc_port`パラメータ
- `mcp-server/src/tools/instances.ts` - `nvim_list_instances`ツール定義
- `mcp-server/src/handlers/instances.ts` - インスタンス一覧取得ハンドラー
- `mcp-server/src/handlers/buffer.ts` - バッファツールの`rpc_port`対応
- `mcp-server/src/handlers/*.ts` - 全ハンドラーの`rpc_port`対応

### ドキュメント

- `docs/multi-instance-testing.md` - テストガイドとアーキテクチャ図解

## 使用例

### インスタンス一覧の取得

```javascript
// Get all running Neovim instances
const result = await use_mcp_tool('vibing-nvim', 'nvim_list_instances', {});
const instances = JSON.parse(result).instances;

console.log(instances);
// [
//   { pid: 1234, port: 9876, cwd: "/proj1", started_at: 1704470400 },
//   { pid: 5678, port: 9877, cwd: "/proj2", started_at: 1704470500 },
//   { pid: 9012, port: 9878, cwd: "/proj3", started_at: 1704470600 }
// ]
```

### 特定インスタンスへの操作

```javascript
// Get buffer from instance on port 9877
const content = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9877,
});

// Set buffer in instance on port 9878
await use_mcp_tool('vibing-nvim', 'nvim_set_buffer', {
  rpc_port: 9878,
  content: 'Hello from Claude!',
});

// Execute command in instance on port 9876
await use_mcp_tool('vibing-nvim', 'nvim_execute', {
  rpc_port: 9876,
  command: 'write',
});
```

### デフォルト動作（後方互換性）

```javascript
// No rpc_port specified - defaults to port 9876
const content = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {});
```

## レビューフィードバック対応

実装後、以下のレビューフィードバックを受けて改善を実施しました：

### CodeRabbit Review (Commit: 47daa96)

1. **Prettierフォーマット**: ドキュメントのフォーマット修正
2. **非同期ファイル操作**: `fs.promises`を使用してイベントループをブロックしないように変更
3. **レース条件対策**: ファイル削除時の`fs.access()`+`fs.unlink()`パターンでエラー処理を追加
4. **冗長コード削除**: `callNeovim()`の重複した初期化コードを削除

### Claude Review (Commit: 473b55b)

1. **Windowsパス一貫性**: `getRegistryPath()`にプラットフォーム固有の詳細コメントを追加
2. **ソケットエラーハンドリング**: 接続前/接続後のエラーを区別して適切に処理
3. **ソケットクリーンアップ**: bind/listen失敗時のnil チェック追加で堅牢性向上

## 参考資料

- Issue #212: "neovim複数立ち上げても問題ないように"
- PR #255: Multi-instance Neovim support implementation
- `docs/multi-instance-testing.md`: 詳細なテストガイドとアーキテクチャ図解
