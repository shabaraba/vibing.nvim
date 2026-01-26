# ADR 008: Agent SDK allowedTools Bypass Issue and Resolution

## Status

Accepted

## Context

vibing.nvim implements a granular permission system with three layers:

1. **Allow list** (`permissions_allow`) - Tools that are generally permitted
2. **Ask list** (`permissions_ask`) - Tools that require user approval despite being allowed
3. **Deny list** (`permissions_deny`) - Tools that are completely blocked

The system is designed to support patterns like:

```yaml
permissions_allow:
  - Bash
permissions_ask:
  - Bash(rm:*)
```

This configuration should:

- Allow most Bash commands to execute freely
- Require user approval specifically for `rm` commands

However, we discovered that `permissions_ask` patterns were being completely ignored, causing security vulnerabilities where dangerous commands like `rm ~/.pm/secret_key_backup.txt` executed without user approval.

## Problem

### Root Cause

Agent SDK's `allowedTools` option automatically approves matching tools **without invoking the `canUseTool` callback**.

In `bin/agent-wrapper.ts`, we were passing `allowedTools` to Agent SDK:

```typescript
// PROBLEMATIC CODE
function buildQueryOptions(config) {
  const options = {
    canUseTool: createCanUseToolCallback(config),
  };

  if (config.allowedTools.length > 0) {
    options.allowedTools = config.allowedTools; // ❌ Bypasses canUseTool!
  }

  return options;
}
```

**Execution flow with allowedTools**:

1. User's frontmatter: `permissions_allow: [Bash]`
2. Lua passes `--allow Bash` to agent-wrapper
3. agent-wrapper sets `allowedTools: ['Bash']` in Agent SDK options
4. Agent SDK sees tool `Bash` in `allowedTools`
5. **Agent SDK auto-approves without calling `canUseTool`** ❌
6. `permissions_ask: [Bash(rm:*)]` check never executes

### Security Impact

- Dangerous commands executed without approval
- `permissions_ask` patterns completely non-functional
- Users unable to restrict specific command patterns within broader tool categories

### Investigation Journey

1. **Initial hypothesis**: Priority order issue in `canUseTool` callback
   - Moved ask list check after allow list check
   - **Did not solve the problem**

2. **Debug logging**: Added extensive logging to `canUseTool`
   - **Logs never appeared** - callback wasn't being called at all

3. **Root cause discovery**: Agent SDK's `allowedTools` was bypassing `canUseTool`

## Decision

**Do not pass `allowedTools` to Agent SDK. Handle all permission logic exclusively in `canUseTool` callback.**

### Implementation

```typescript
// FIXED CODE
function buildQueryOptions(config) {
  const options = {
    canUseTool: createCanUseToolCallback(config),
  };

  // IMPORTANT: DO NOT pass allowedTools to Agent SDK!
  // Agent SDK's allowedTools bypasses canUseTool callback for matching tools.
  // We handle all permission logic in canUseTool callback for granular control.
  // if (config.allowedTools.length > 0) {
  //   options.allowedTools = config.allowedTools;
  // }

  return options;
}
```

**New execution flow**:

1. User's frontmatter: `permissions_allow: [Bash]`, `permissions_ask: [Bash(rm:*)]`
2. Lua passes `--allow Bash --ask Bash(rm:*)` to agent-wrapper
3. agent-wrapper creates `canUseTool` callback with both lists
4. **Agent SDK calls `canUseTool` for every tool use** ✅
5. `canUseTool` checks allow list → `Bash` matches, continue
6. `canUseTool` checks ask list → `Bash(rm:*)` matches, **request approval** ✅

### Permission Evaluation Order in `canUseTool`

```typescript
export function createCanUseToolCallback(config) {
  return async (toolName, input) => {
    // 1. Session-level deny list (highest priority)
    // 2. Session-level allow list
    // 3. Permission modes (acceptEdits, default, bypassPermissions)
    // 4. Allow list (with pattern support)
    if (allowedTools.length > 0) {
      const isAllowed = allowedTools.some((pattern) => matchesPermission(toolName, input, pattern));
      if (!isAllowed) {
        return deny('Not in allow list');
      }
      // Continue to next check (do NOT auto-approve)
    }

    // 5. Ask list (granular patterns override broader permissions)
    const requiresApproval = askedTools.some((pattern) =>
      matchesPermission(toolName, input, pattern)
    );
    if (requiresApproval) {
      return requestApproval(toolName, input); // ✅ Shows approval UI
    }

    // 6. Granular permission rules
    // 7. Final allow
    return allow(input);
  };
}
```

## Consequences

### Positive

- **Security**: `permissions_ask` patterns now work correctly
- **Granular control**: Specific patterns can override broader permissions
- **Consistency**: All permission logic in one place (`canUseTool`)
- **Debugging**: Easier to trace permission decisions with single code path

### Negative

- **Performance**: Every tool use goes through `canUseTool` callback (minimal impact)
- **Agent SDK convention**: Deviates from standard `allowedTools` usage (acceptable trade-off)

### Neutral

- `AskUserQuestion` tool continues to work correctly (handled specially in `canUseTool`)
- `disallowedTools` (deny list) still passed to Agent SDK as additional safety layer

## Related Tools and Patterns

### Tools affected by this fix

- `Bash` - Most critical (dangerous commands like `rm`, `sudo`)
- `Edit`, `Write` - File modification tools
- `Read`, `Glob`, `Grep` - File access tools
- All MCP tools (e.g., `mcp__vibing-nvim__*`)

### Pattern matching

The permission system supports granular patterns:

- `Bash` - All Bash commands
- `Bash(rm:*)` - Only `rm` commands (bash_wildcard pattern)
- `Bash(rm -rf /)` - Exact command match (bash_exact pattern)
- `Read(*.secret)` - File glob pattern
- `WebFetch(github.com)` - Domain pattern

## Example Use Cases

### Use Case 1: Safe general Bash usage with dangerous command protection

```yaml
permissions_allow:
  - Bash
permissions_ask:
  - Bash(rm:*)
  - Bash(sudo:*)
  - Bash(dd:*)
```

Result: Git commands, npm commands, etc. execute freely. Dangerous commands require approval.

### Use Case 2: Development workflow with selective approval

```yaml
permission_mode: acceptEdits # Auto-approve Edit/Write
permissions_allow:
  - Read
  - Glob
  - Grep
  - Bash
permissions_ask:
  - Bash(npm install:*) # Confirm package installations
  - Bash(git push:*) # Confirm remote pushes
```

Result: Fast development workflow, but critical operations require confirmation.

## References

- Issue: `rm ~/.pm/secret_key_backup.txt` executed without approval
- Commit: `b07f5dc` - Fix: prevent Agent SDK from bypassing permissions_ask checks
- Related ADR: `001-permissions-ask-implementation.md`
- Files changed:
  - `bin/agent-wrapper.ts` - Remove `allowedTools` from Agent SDK options
  - `bin/lib/permissions/can-use-tool.ts` - Refactor with helper functions

## Lessons Learned

1. **Framework behavior assumptions**: Always verify how frameworks handle configuration options
2. **Debug logging placement**: Log at framework boundaries, not just application code
3. **Security testing**: Test negative cases (should deny) not just positive cases (should allow)
4. **Documentation reading**: Agent SDK's `allowedTools` behavior should have been understood upfront
