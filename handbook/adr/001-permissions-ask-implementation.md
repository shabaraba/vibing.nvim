# ADR 001: Permissions Ask Implementation and Agent SDK Constraints

## Status

Accepted

## Date

2025-01-26

## Context

Issue #174 required implementing a three-tier permission system (deny → ask → allow) for vibing.nvim. The `permissions_ask` feature allows users to mark specific tools for manual approval before use.

However, the Claude Agent SDK has several undocumented behaviors and constraints that significantly impacted the design:

### Agent SDK Constraints Discovered

1. **`permissionMode` bypasses `canUseTool`**
   - Setting ANY `permissionMode` value (including `'default'` or `'acceptEdits'`) causes the SDK to bypass the `canUseTool` callback entirely
   - This was the root cause of permission logic failures during development
   - Documented in code comment at bin/agent-wrapper.mjs:229-231

2. **Issue #29: Resume Session Bypass**
   - In resumed sessions (with `sessionId`), the Agent SDK bypasses both `allowedTools` whitelist and `canUseTool` callback
   - This is a confirmed SDK bug tracked at: https://github.com/anthropics/claude-agent-sdk-typescript/issues/29
   - No fix available as of SDK version 0.1.76

3. **Permission System Layers**
   - The SDK has multiple permission layers with specific precedence:
     ```
     PreToolUse Hook → Deny Rules → Allow Rules → Ask Rules → permissionMode → canUseTool
     ```
   - `canUseTool` is the LOWEST priority layer
   - Any higher layer can completely override `canUseTool` behavior

4. **`allowedTools` vs `canUseTool` Interaction**
   - Setting `allowedTools` forces `canUseTool` to be called for non-whitelisted tools
   - However, whitelisted tools bypass `canUseTool` entirely
   - This prevents granular pattern matching on allowed tools

## Decision

### Architecture: Custom Permission Logic in `canUseTool`

We implemented the three-tier permission system entirely within the `canUseTool` callback, with specific workarounds for SDK constraints:

#### 1. Never Set `permissionMode` (Except `bypassPermissions`)

```javascript
// CRITICAL: Do NOT set permissionMode (even to 'default')
// Setting ANY permissionMode value causes SDK to bypass canUseTool callback
// Leave it undefined to ensure canUseTool is called for all tools
allowDangerouslySkipPermissions: permissionMode === 'bypassPermissions',
```

**Rationale:**

- Only way to ensure `canUseTool` is always invoked
- `acceptEdits` mode is implemented manually inside `canUseTool` instead of relying on SDK

#### 2. Issue #29 Workaround: Deny Ask-listed Tools in Resume Sessions

```javascript
if (sessionId) {
  // Resume session: deny to prevent bypass (Issue #29)
  return {
    behavior: 'deny',
    message: `Tool ${toolName} requires user approval before use. Add it to the allow list with /allow ${askedTool} to enable in resume sessions.`,
  };
} else {
  // New session: ask for user confirmation (normal behavior)
  return {
    behavior: 'ask',
    updatedInput: input,
  };
}
```

**Rationale:**

- In resume sessions, `canUseTool` would be bypassed anyway (Issue #29)
- Preemptively denying with helpful message prevents silent auto-approval
- Guides users to add tools to allow list for permanent approval
- Trade-off: Users cannot use ask-listed tools in resumed sessions

#### 3. Permission Priority: deny > ask > allow

Implemented as explicit cascading checks in `canUseTool`:

1. Check `deniedTools` → immediate deny (handled by SDK's `disallowedTools`)
2. Check `askedTools` → ask (or deny in resume sessions)
3. Check `allowedTools` → allow
4. Default → follow `permissionMode` behavior

**Rationale:**

- Matches security best practices (deny takes precedence)
- Clear, predictable behavior for users
- Allows "allow override" pattern (adding to allow list overrides ask list)

#### 4. Granular Pattern Matching

Implemented custom pattern parsing for all tools:

```javascript
// Tool(pattern) syntax examples:
Bash(npm install)       // exact command match
Bash(git:*)             // wildcard match
Read(src/**/*.ts)       // file glob pattern
WebFetch(github.com)    // domain pattern
```

**Rationale:**

- SDK's `allowedTools` doesn't support granular patterns
- Custom implementation in `canUseTool` provides full flexibility
- Consistent syntax across all tool types

## Consequences

### Positive

- ✅ Three-tier permission system works reliably
- ✅ Granular pattern matching for fine-grained control
- ✅ Issue #29 is mitigated with helpful user guidance
- ✅ `acceptEdits` mode works correctly (implemented in `canUseTool`)
- ✅ Clear error messages guide users toward solutions

### Negative

- ❌ Ask-listed tools cannot be used in resumed sessions (Issue #29 limitation)
- ❌ Must maintain custom permission logic instead of relying on SDK
- ❌ `permissionMode` feature is essentially disabled (except `bypassPermissions`)
- ⚠️ Code complexity: all permission logic in single `canUseTool` function

### Risks and Mitigations

**Risk 1: Future SDK updates may change behavior**

- _Mitigation_: Comprehensive test coverage (tests/permission-logic.test.mjs)
- _Mitigation_: Detailed documentation of SDK constraints in code comments

**Risk 2: Issue #29 may never be fixed**

- _Mitigation_: Current workaround is stable and provides good UX
- _Mitigation_: Clear error messages explain limitation to users

**Risk 3: Custom implementation may diverge from SDK best practices**

- _Mitigation_: Regular review of SDK documentation and updates
- _Mitigation_: ADR documents rationale for deviations

## Alternatives Considered

### Alternative 1: Use SDK's `permissionMode` + `allowedTools`

**Rejected because:**

- `permissionMode` bypasses `canUseTool`, preventing ask functionality
- `allowedTools` doesn't support granular patterns
- Cannot implement three-tier system with SDK features alone

### Alternative 2: Implement permission logic in PreToolUse hook

**Rejected because:**

- PreToolUse hook is external to Agent SDK wrapper
- Issue #29 bypass happens inside SDK, too late for hook intervention
- Would require duplicating logic in both hook and wrapper

### Alternative 3: Use `disallowedTools` for deny list

**Partially adopted:**

- We DO use `disallowedTools` for the deny list (most reliable SDK feature)
- But cannot use it for ask list (would cause complete block, not prompt)

## References

- Issue #174: Add "ask" permission tier alongside allow/deny
- Issue #29 (Agent SDK): Resume session bypasses allowedTools and canUseTool
  - https://github.com/anthropics/claude-agent-sdk-typescript/issues/29
- Chat history: .vibing/chat/permissions-ask-sdk-constraints-investigation.vibing
- Implementation: bin/agent-wrapper.mjs (lines 559-700)
- Tests: tests/permission-logic.test.mjs

## Notes

This ADR documents one of the most challenging implementation decisions in vibing.nvim due to the gap between ideal design and SDK constraints. Future maintainers should:

1. Check if Issue #29 has been resolved in newer SDK versions
2. Test if `permissionMode` behavior has changed
3. Consider migrating to SDK features if constraints are lifted
4. Keep this ADR updated with any new SDK discoveries
