---
name: debug-issue
description: Debug Issue
---

# Debug Issue

Systematic workflow for investigating and fixing bugs in vibing.nvim.

## When to Use

- User reports a bug or error
- Feature not working as expected
- Performance issues

## Workflow

### 1. Reproduce the Issue

Ask user for:

- Exact steps to reproduce
- Expected vs actual behavior
- Error messages (if any)

### 2. Locate Problem Area

**Use LSP diagnostics:**

```javascript
const diagnostics = await use_mcp_tool('vibing-nvim', 'nvim_diagnostics', {
  rpc_port: rpcPort,
});
```

**Search for error messages:**

```javascript
// Use Grep to find related code
```

**Trace execution:**

```javascript
// Use call hierarchy to understand code flow
const callers = await use_mcp_tool('vibing-nvim', 'nvim_lsp_call_hierarchy_incoming', {
  bufnr: bufnr,
  line: suspectLine,
  col: 0,
  rpc_port: rpcPort,
});
```

### 3. Analyze Root Cause

- Review relevant code
- Check recent changes (git log)
- Identify assumptions or edge cases

### 4. Create Fix Worktree

```
:VibingChatWorktree fix-<issue-description>
```

### 5. Implement Fix

- Fix the root cause
- Add edge case handling
- Consider adding regression test

### 6. Verify Fix

```bash
npm run build && npm test
```

Test manually in Neovim:

- Reload plugin: `:Lazy reload vibing.nvim`
- Reproduce original issue
- Confirm fix works

### 7. Report Findings

Provide user with:

- Root cause explanation
- Fix implementation details
- Test results

## Tips

**Common Bug Sources:**

- Nil/undefined checks
- Async timing issues
- Buffer/window state synchronization
- Permission handling edge cases

**Debugging Tools:**

- LSP diagnostics
- Call hierarchy (incoming/outgoing)
- References analysis
- Grep for error patterns
