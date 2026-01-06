# Multi-Instance Testing Guide

This document describes how to test the multi-instance Neovim support with vibing.nvim MCP integration.

## Overview

The multi-instance feature allows Claude Code to interact with multiple running Neovim instances simultaneously. Each instance runs its own RPC server on a different port (9876-9885), and instances are tracked in a registry.

## Architecture Diagrams

### Before: Single Instance Only (Problem)

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

**Problem:**

- Fixed port 9876 for all instances
- Second instance cannot bind (port already in use)
- MCP Server connects to fixed port (only first instance reachable)
- No way to discover or target other instances

### After: Multi-Instance Support (Solution)

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

**Solution:**

- Dynamic port allocation (9876-9885 range)
- Instance registry tracks PID, port, cwd, timestamp
- MCP Server maintains socket pool (one per port)
- All tools accept optional `rpc_port` parameter
- New `nvim_list_instances` tool for discovery

### Communication Flow

```text
Step 1: Instance Discovery
─────────────────────────────

Claude Code                      Registry (Filesystem)
     │                                  │
     │  nvim_list_instances()           │
     ├──────────────────────────────────>│
     │                                  │
     │  Read all *.json files           │
     │  Check process liveness          │
     │  Cleanup stale entries           │
     │                                  │
     │  Return: [                       │
     │    {pid:1234, port:9876, ...},   │
     │    {pid:5678, port:9877, ...}    │
     │  ]                               │
     │<──────────────────────────────────│
     │                                  │


Step 2: Tool Execution (with port)
──────────────────────────────────

Claude Code              Socket Pool              Neovim (port 9877)
     │                        │                            │
     │  nvim_get_buffer({     │                            │
     │    rpc_port: 9877      │                            │
     │  })                    │                            │
     ├───────────────────────>│                            │
     │                        │                            │
     │                        │  getSocket(9877)           │
     │                        │  (create if not exists)    │
     │                        │                            │
     │                        │  JSON-RPC request:         │
     │                        │  {"id":1, "method":        │
     │                        │   "buf_get_lines", ...}    │
     │                        ├───────────────────────────>│
     │                        │                            │
     │                        │  Process via vim.schedule()│
     │                        │  Execute API call          │
     │                        │                            │
     │                        │  JSON-RPC response:        │
     │                        │  {"id":1, "result":[...]}  │
     │                        │<───────────────────────────│
     │                        │                            │
     │  Buffer content        │                            │
     │<───────────────────────│                            │
     │                        │                            │


Step 3: Default Behavior (no port)
──────────────────────────────────

Claude Code              Socket Pool              Neovim (port 9876)
     │                        │                            │
     │  nvim_get_buffer({     │                            │
     │    // no rpc_port      │                            │
     │  })                    │                            │
     ├───────────────────────>│                            │
     │                        │                            │
     │                        │  getSocket(9876)           │
     │                        │  (default port)            │
     │                        ├───────────────────────────>│
     │                        │                            │
     │  Buffer content        │                            │
     │<───────────────────────┼────────────────────────────│
     │                        │                            │
```

## Architecture Changes

### 1. Dynamic Port Allocation (Lua)

**File:** `lua/vibing/infrastructure/rpc/server.lua`

- RPC server tries ports 9876-9885 in sequence
- First available port is used
- Port information is stored in instance registry

### 2. Instance Registry (Lua)

**File:** `lua/vibing/infrastructure/rpc/registry.lua`

- Registry location: `~/.local/share/nvim/vibing-instances/`
- Each instance has a JSON file: `{pid}.json`
- Contains: pid, port, cwd, started_at
- Stale entries (dead processes) are automatically cleaned up

### 3. Multi-Port Socket Management (TypeScript)

**File:** `mcp-server/src/rpc.ts`

- Maintains separate sockets for each port
- `callNeovim(method, params, port?)` accepts optional port parameter
- Pending requests tracked per-port
- Buffers managed per-port

### 4. MCP Tools Enhanced

**Files:** `mcp-server/src/tools/*.ts`, `mcp-server/src/handlers/*.ts`

- All tools accept optional `rpc_port` parameter
- New tool: `nvim_list_instances` - lists all running instances

## Testing Steps

### Test 1: Basic Multi-Instance

```bash
# Terminal 1: Start first Neovim
$ nvim test1.txt

# In Neovim 1
:lua require("vibing").setup({ mcp = { enabled = true } })
# Expected: "RPC server started on port 9876"

# Terminal 2: Start second Neovim
$ nvim test2.txt

# In Neovim 2
:lua require("vibing").setup({ mcp = { enabled = true } })
# Expected: "RPC server started on port 9877"

# Terminal 3: Start third Neovim
$ nvim test3.txt

# In Neovim 3
:lua require("vibing").setup({ mcp = { enabled = true } })
# Expected: "RPC server started on port 9878"
```

### Test 2: Registry Verification

```bash
# Check registry files
$ ls -la ~/.local/share/nvim/vibing-instances/
# Expected: Multiple .json files (one per running instance)

# Inspect registry contents
$ cat ~/.local/share/nvim/vibing-instances/*.json | jq -s .
# Expected: Array of instance data with different PIDs and ports
```

### Test 3: MCP Tool Usage

From Claude Code (or direct MCP client):

```javascript
// List all instances
const result = await use_mcp_tool('vibing-nvim', 'nvim_list_instances', {});
const instances = JSON.parse(result).instances;
console.log(instances);
// Expected: Array of 3 instances with ports 9876, 9877, 9878

// Get buffer from first instance (port 9876)
const content1 = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9876,
});
console.log('Instance 1 content:', content1);

// Get buffer from second instance (port 9877)
const content2 = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: 9877,
});
console.log('Instance 2 content:', content2);

// Default instance (no rpc_port specified - uses 9876)
const contentDefault = await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {});
console.log('Default instance:', contentDefault);
```

### Test 4: Port Exhaustion

```bash
# Start 10 Neovim instances
for i in {1..10}; do
  nvim -c "lua require('vibing').setup({ mcp = { enabled = true } })" test$i.txt &
done

# Expected: First 10 instances get ports 9876-9885
# 11th instance should fail with error message

# Cleanup
pkill -f "nvim.*test"
```

### Test 5: Cleanup Verification

```bash
# Check registry before cleanup
$ ls ~/.local/share/nvim/vibing-instances/ | wc -l
# Expected: Number of running instances

# Kill one Neovim instance
$ pkill -f "nvim.*test1"

# List instances via MCP (triggers cleanup)
$ # Use nvim_list_instances tool
# Expected: Stale registry file for killed process is removed

# Verify cleanup
$ ls ~/.local/share/nvim/vibing-instances/ | wc -l
# Expected: One fewer file
```

## Expected Behavior

### ✅ Success Criteria

1. **Dynamic Port Allocation:**
   - First instance: port 9876
   - Second instance: port 9877
   - Third instance: port 9878
   - Up to 10 instances supported (ports 9876-9885)

2. **Registry Management:**
   - Each running instance has a registry file
   - Registry contains correct PID, port, cwd
   - Stale entries cleaned up automatically

3. **MCP Tools:**
   - `nvim_list_instances` returns all running instances
   - All tools accept optional `rpc_port` parameter
   - Tools work correctly with specified port
   - Default behavior (no rpc_port) uses port 9876

4. **Backward Compatibility:**
   - Single instance works exactly as before
   - Default port is still 9876
   - Existing configurations require no changes

### ❌ Known Limitations

1. **Maximum 10 Instances:**
   - Port range: 9876-9885 (10 ports)
   - 11th instance will fail to start RPC server

2. **Manual Port Selection:**
   - Users must remember or query which port corresponds to which instance
   - Future enhancement: automatic focus detection

3. **Registry Cleanup:**
   - Stale entries cleaned on next `nvim_list_instances` call
   - Not cleaned immediately when process dies

## Troubleshooting

### Issue: "Failed to start RPC server: all ports are in use"

**Cause:** More than 10 instances trying to start

**Solution:**

```bash
# Clean up stale processes
pkill nvim

# Remove stale registry files
rm -rf ~/.local/share/nvim/vibing-instances/*

# Restart Neovim instances
```

### Issue: Tool returns wrong instance data

**Cause:** Incorrect `rpc_port` parameter

**Solution:**

```javascript
// Always check available instances first
const { instances } = JSON.parse(await use_mcp_tool('vibing-nvim', 'nvim_list_instances', {}));

// Use correct port from instances list
const targetPort = instances[0].port;
await use_mcp_tool('vibing-nvim', 'nvim_get_buffer', {
  rpc_port: targetPort,
});
```

### Issue: Connection refused

**Cause:** Instance already exited, but registry not cleaned

**Solution:**

```javascript
// nvim_list_instances automatically cleans stale entries
await use_mcp_tool('vibing-nvim', 'nvim_list_instances', {});

// Retry the operation
```

## Implementation Files

### Lua Files (Neovim)

- `lua/vibing/infrastructure/rpc/server.lua` - Dynamic port allocation
- `lua/vibing/infrastructure/rpc/registry.lua` - Instance registry management

### TypeScript Files (MCP Server)

- `mcp-server/src/rpc.ts` - Multi-port socket management
- `mcp-server/src/tools/common.ts` - Shared rpc_port property
- `mcp-server/src/tools/instances.ts` - nvim_list_instances tool
- `mcp-server/src/handlers/instances.ts` - Instance listing handler
- `mcp-server/src/handlers/buffer.ts` - Updated with rpc_port support

## Next Steps

1. Test with real Claude Code sessions
2. Add automatic instance selection (e.g., by CWD matching)
3. Implement instance labeling/naming
4. Add MCP tool to get "current" or "focused" instance
5. Consider supporting custom port ranges via config

## Summary

The multi-instance feature is complete and ready for testing. All existing functionality remains backward-compatible, while new capabilities enable Claude Code to work with multiple Neovim instances simultaneously.
