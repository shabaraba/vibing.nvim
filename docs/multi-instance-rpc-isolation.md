# Multi-Instance RPC Isolation

## Overview

This document explains how vibing.nvim's RPC server architecture ensures complete isolation between multiple Neovim instances, preventing any interference or cross-instance communication.

## Architecture

### Port Assignment Strategy

Each Neovim instance is automatically assigned a unique port from the range 9876-9885:

```lua
-- lua/vibing/infrastructure/rpc/server.lua
function M.start(base_port)
  base_port = base_port or 9876
  local max_attempts = 10

  for i = 0, max_attempts - 1 do
    local try_port = base_port + i

    -- Skip if port is already in use
    if registry.is_port_in_use(try_port) then
      goto continue
    end

    -- Try to bind to this port
    server = uv.new_tcp()
    local bind_ok = server:bind("127.0.0.1", try_port)

    if bind_ok then
      -- Success! Register this instance
      registry.register(try_port)
      return try_port
    end

    ::continue::
  end
end
```

**Key Points:**

- First instance → port 9876
- Second instance → port 9877
- Up to 10 instances supported (9876-9885)
- Automatic collision avoidance

### Instance Registry

Each instance maintains its own registry file at:

```
~/.local/share/nvim/vibing-instances/{pid}.json
```

Registry content:

```json
{
  "pid": 12345,
  "port": 9877,
  "cwd": "/path/to/project",
  "started_at": 1704470400
}
```

**Isolation guarantees:**

- One file per process (PID-based naming)
- No shared state between instances
- Automatic cleanup on process termination

### Socket Management (MCP Server)

The TypeScript MCP server maintains a socket pool:

```typescript
// mcp-server/src/rpc.ts
const sockets = new Map<number, net.Socket>();
const pendingRequests = new Map<number, Map<number, Pending>>();
const buffers = new Map<number, string>();
```

**Isolation guarantees:**

- Independent socket per port
- Independent request queue per port
- Independent buffer per port
- No cross-port communication

## How Isolation Works

### 1. Network Layer Isolation

```text
┌─────────────────────────────────────┐
│ Neovim Instance 1 (PID: 1234)       │
│  └─ RPC Server: 127.0.0.1:9876 ✅   │
│      └─ Only accepts connections    │
│          on port 9876               │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ Neovim Instance 2 (PID: 5678)       │
│  └─ RPC Server: 127.0.0.1:9877 ✅   │
│      └─ Only accepts connections    │
│          on port 9877               │
└─────────────────────────────────────┘

          ↓ Network isolation ↓
    No shared network channel
    No cross-instance traffic
```

### 2. Process Isolation

```text
┌────────────────────────────────┐
│ OS Process 1234                │
│  ├─ Memory space: isolated     │
│  ├─ File descriptors: isolated │
│  └─ Network sockets: isolated  │
└────────────────────────────────┘

┌────────────────────────────────┐
│ OS Process 5678                │
│  ├─ Memory space: isolated     │
│  ├─ File descriptors: isolated │
│  └─ Network sockets: isolated  │
└────────────────────────────────┘
```

### 3. Registry Isolation

```text
~/.local/share/nvim/vibing-instances/
├── 1234.json  ← Instance 1 only
├── 5678.json  ← Instance 2 only
└── 9012.json  ← Instance 3 only

No shared registry file
No shared state
```

### 4. Socket Pool Isolation

```text
MCP Server Socket Pool:
├── socket[9876] → Instance 1 only
├── socket[9877] → Instance 2 only
└── socket[9878] → Instance 3 only

Each socket:
  ├─ Independent connection
  ├─ Independent request queue
  └─ Independent buffer
```

## Example Usage

### Working with Multiple Instances

```javascript
// List all running instances
const result = await use_mcp_tool('vibing-nvim', 'nvim_list_instances', {});
const instances = JSON.parse(result).instances;

// instances = [
//   { pid: 1234, port: 9876, cwd: "/proj1" },
//   { pid: 5678, port: 9877, cwd: "/proj2" },
//   { pid: 9012, port: 9878, cwd: "/proj3" }
// ]

// Operate on Instance 1 (port 9876)
await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9876,
});

// Operate on Instance 2 (port 9877) - completely isolated
await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9877,
});
```

### Explicit Port Targeting

All MCP tools accept an optional `rpc_port` parameter:

```javascript
// Read buffer from Instance 2
const content = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9877,
  bufnr: 0,
});

// Execute command on Instance 3
await use_mcp_tool('vibing-nvim', 'nvim_execute', {
  rpc_port: 9878,
  command: 'write',
});

// LSP operation on Instance 1
await use_mcp_tool('vibing-nvim', 'nvim_lsp_definition', {
  rpc_port: 9876,
  line: 10,
  col: 5,
});
```

## Guarantees

### What IS Isolated

✅ **Network Sockets**: Each instance has its own TCP server on a unique port
✅ **Process Memory**: OS-level process isolation (separate memory spaces)
✅ **File Descriptors**: Each instance has its own set of file handles
✅ **RPC State**: Independent request queues, buffers, and pending requests
✅ **Registry Files**: One JSON file per process (PID-based naming)
✅ **Port Binding**: Automatic collision detection and avoidance

### What is NOT Shared

❌ **No shared memory**: Each process has its own address space
❌ **No shared sockets**: Each instance binds to a unique port
❌ **No shared registry**: One file per PID, no cross-process access
❌ **No shared state**: Independent buffers, queues, and connection pools
❌ **No IPC**: No inter-process communication between instances

## Limitations

1. **Maximum 10 instances**: Port range is 9876-9885
2. **Manual port specification**: User must explicitly specify `rpc_port` when operating on non-default instance
3. **Default port behavior**: Omitting `rpc_port` always targets port 9876

## Related Documentation

- [ADR 004: Multi-Instance Neovim Support](./adr/004-multi-instance-neovim-support.md)
- [Multi-Instance Testing Guide](./multi-instance-testing.md)

## Conclusion

vibing.nvim's RPC architecture provides **complete isolation** between multiple Neovim instances through:

1. **Network-level separation**: Unique ports per instance
2. **Process-level separation**: OS-enforced memory and resource isolation
3. **File-level separation**: PID-based registry files
4. **Socket-level separation**: Independent connection pools

**There is no mechanism for cross-instance interference.** Each instance operates in its own isolated environment.
