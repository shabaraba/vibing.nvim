# Permissions Ask Feature Specification

## Overview

The `permissions_ask` feature introduces a third permission tier for vibing.nvim, allowing users to mark specific tools for manual approval before each use. This sits between the `permissions_deny` (always blocked) and `permissions_allow` (auto-approved) tiers.

**Priority Order:** deny > ask > allow

## User Interface

### Slash Commands

#### `/ask [tool]`

Add or remove tools from the ask list.

**Syntax:**

```
/ask                      # Show current ask list
/ask <tool>               # Add tool to ask list
/ask -<tool>              # Remove tool from ask list
/ask <Tool(pattern)>      # Add tool with granular pattern
```

**Examples:**

```
/ask Bash                 # Require approval for all Bash commands
/ask Bash(git:*)          # Require approval for git commands only
/ask Read(src/**/*.ts)    # Require approval for TypeScript files in src/
/ask -Bash                # Remove Bash from ask list
```

**Behavior:**

- Without arguments: displays current ask list
- With tool name: adds to `permissions_ask` frontmatter list
- With `-` prefix: removes from ask list
- Validates tool name against known tools
- Supports granular pattern syntax (see Pattern Matching section)

#### `/allow` and `/deny` Interaction

**Allow Overrides Ask:**
If a tool is in both `permissions_ask` and `permissions_allow`:

- Tool is **auto-approved** (allow takes precedence)
- Notification shown: "Note: Allow list overrides ask list - tool will be auto-approved"

**Deny Overrides All:**
If a tool is in `permissions_deny`:

- Tool is **completely blocked** regardless of ask/allow lists
- No approval prompt shown

### Permission Builder UI

The interactive `/permissions` command includes "ask" as a permission type option:

```
Permission type:
  [ ] allow
  [x] ask    ← Select this
  [ ] deny
```

After selecting "ask", users can:

1. Choose tool from list
2. Optionally specify granular pattern
3. Tool is added to `permissions_ask` frontmatter

### Frontmatter Format

```yaml
---
vibing.nvim: true
session_id: abc123
permissions_mode: acceptEdits
permissions_allow:
  - Read
  - Edit
  - Write
permissions_ask:
  - Bash
  - Bash(npm:*)
  - WebFetch(github.com)
permissions_deny:
  - Bash(rm -rf)
---
```

## Permission Evaluation Flow

### New Sessions (No `session_id`)

```
┌─────────────────────────────────────────────┐
│ Tool Use Request                            │
└─────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│ 1. Check permissions_deny                   │
│    Match? → DENY                            │
└─────────────────────────────────────────────┘
                  │ No match
                  ▼
┌─────────────────────────────────────────────┐
│ 2. Check permissions_ask                    │
│    Match? → ASK USER FOR APPROVAL           │
│             ├─ Approve → Execute            │
│             └─ Deny → Block                 │
└─────────────────────────────────────────────┘
                  │ No match
                  ▼
┌─────────────────────────────────────────────┐
│ 3. Check permissions_allow                  │
│    Match? → ALLOW                           │
└─────────────────────────────────────────────┘
                  │ No match
                  ▼
┌─────────────────────────────────────────────┐
│ 4. Apply permission mode                    │
│    - default: ASK                           │
│    - acceptEdits: ALLOW if Edit/Write       │
│    - bypassPermissions: ALLOW               │
└─────────────────────────────────────────────┘
```

### Resumed Sessions (With `session_id`)

**Important:** Due to Agent SDK Issue #29, ask-listed tools behave differently in resumed sessions.

```
┌─────────────────────────────────────────────┐
│ Tool Use Request (Resume Session)           │
└─────────────────────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────┐
│ 1. Check permissions_deny                   │
│    Match? → DENY                            │
└─────────────────────────────────────────────┘
                  │ No match
                  ▼
┌─────────────────────────────────────────────┐
│ 2. Check permissions_ask                    │
│    Match? → DENY WITH HELPFUL MESSAGE       │
│    "Add to allow list to enable in resume"  │
└─────────────────────────────────────────────┘
                  │ No match
                  ▼
         (Continue with allow/mode checks)
```

**Rationale:** Agent SDK Issue #29 causes `canUseTool` callback to be bypassed in resumed sessions. To prevent silent auto-approval, we preemptively deny ask-listed tools with guidance to add them to the allow list.

## Pattern Matching

### Supported Pattern Types

#### 1. Simple Tool Name

```
Bash          # Matches all Bash commands
Read          # Matches all Read operations
```

#### 2. Bash Command Patterns

```
Bash(npm install)       # Exact match: "npm install"
Bash(npm:*)             # Wildcard: any npm command (npm install, npm test, etc.)
Bash(git:*)             # Wildcard: any git command
Bash(git commit:*)      # Wildcard: git commit with any args
```

**Matching Logic:**

- `exact`: Command must exactly match pattern
- `bash_wildcard`: Pattern with `:*` matches command prefix
  - `npm:*` matches "npm install", "npm test", "npm run build"
  - `git commit:*` matches "git commit -m 'msg'", "git commit --amend"

#### 3. File Glob Patterns (Read/Write/Edit)

```
Read(src/**/*.ts)       # All TypeScript files in src/ and subdirs
Write(*.json)           # All JSON files in current dir
Edit(config/*.yaml)     # YAML files in config/ dir
```

**Glob Syntax:**

- `*` - Matches any characters except `/`
- `**` - Matches any characters including `/` (recursive)
- `?` - Matches single character
- `{a,b}` - Matches `a` or `b`

#### 4. Domain Patterns (WebFetch/WebSearch)

```
WebFetch(github.com)        # Exact domain match
WebFetch(*.npmjs.com)       # Wildcard subdomain match
```

**Matching Logic:**

- `github.com` matches `https://github.com/...`
- `*.npmjs.com` matches `https://registry.npmjs.com/...`
- Does NOT match: `api.github.com` for pattern `github.com`

#### 5. Search Patterns (Glob/Grep)

```
Glob(*.js)              # Glob tool searching for .js files
Grep(TODO)              # Grep tool searching for "TODO"
```

### Pattern Matching Implementation

**Location:** `bin/agent-wrapper.mjs` lines 417-557

**Key Functions:**

- `parseToolPattern(permissionStr)` - Parses `Tool(pattern)` syntax
- `matchesPermission(toolName, input, permissionStr)` - Main matching logic
- `matchesBashPattern(command, ruleContent, type)` - Bash-specific matching
- `matchesFileGlob(filePath, globPattern)` - File path matching
- `matchesDomainPattern(url, domainPattern)` - Domain matching

## Implementation Details

### Agent SDK Integration

**File:** `bin/agent-wrapper.mjs`

#### Permission Data Flow

1. **Lua → Node.js:**

   ```lua
   -- lua/vibing/adapters/agent_sdk.lua
   local ask_tools = opts.permissions_ask
   if ask_tools and #ask_tools > 0 then
     table.insert(cmd, "--ask")
     table.insert(cmd, table.concat(ask_tools, ","))
   end
   ```

2. **Command Line Parsing:**

   ```javascript
   // bin/agent-wrapper.mjs
   let askedTools = [];
   if (args[i] === '--ask' && args[i + 1]) {
     askedTools = args[i + 1]
       .split(',')
       .map((t) => t.trim())
       .filter((t) => t);
   }
   ```

3. **canUseTool Callback:**
   ```javascript
   queryOptions.canUseTool = async (toolName, input) => {
     // Check ask list
     for (const askedTool of askedTools) {
       if (matchesPermission(toolName, input, askedTool)) {
         if (sessionId) {
           // Resume session: deny (Issue #29 workaround)
           return { behavior: 'deny', message: '...' };
         } else {
           // New session: ask for approval
           return { behavior: 'ask', updatedInput: input };
         }
       }
     }
     // Continue with allow list check...
   };
   ```

### Error Handling

#### Permission Matching Errors

If pattern matching fails (e.g., malformed pattern, invalid input):

```javascript
} catch (error) {
  const errorMsg = `Permission matching failed for ${toolName} with pattern ${permissionStr}: ${error.message}`;
  console.error('[ERROR]', errorMsg, error.stack);

  // Notify user via JSON Lines protocol (displayed in chat)
  console.log(JSON.stringify({
    type: 'error',
    message: errorMsg,
  }));

  // On error, deny for safety
  return false;
}
```

**User Experience:**

- Error message displayed in chat
- Tool use is blocked (fail-safe behavior)
- User can fix pattern syntax and retry

#### canUseTool Callback Errors

```javascript
} catch (error) {
  console.error('[ERROR] canUseTool failed:', error.message, error.stack);

  // Distinguish between implementation bugs and runtime errors
  if (error instanceof TypeError || error instanceof ReferenceError) {
    // Implementation bugs should fail fast for debugging
    throw error;
  }

  // For other errors, deny for safety but notify user
  return {
    behavior: 'deny',
    message: `Permission check failed due to internal error: ${error.message}. Please report this issue if it persists.`,
  };
}
```

## User Guidance

### Recommended Workflow

1. **Start with ask list for new tools:**

   ```
   /ask Bash
   ```

2. **Test the tool with approval:**
   - Tool use triggers approval prompt
   - Approve once to test

3. **Add to allow list if frequently used:**

   ```
   /allow Bash
   ```

   (This overrides ask list - tool becomes auto-approved)

4. **Use granular patterns for security:**
   ```
   /allow Bash(npm:*)        # Safe: only npm commands
   /allow Bash(git:*)        # Safe: only git commands
   /ask Bash                 # Unsafe: requires approval for ALL Bash
   ```

### Handling Resume Sessions

**Problem:** Ask-listed tools are denied in resumed sessions (Issue #29 workaround).

**Solution 1 (Recommended):** Add to allow list

```
/allow Bash(npm:*)
```

**Solution 2:** Start new session

- Close current chat
- Open new chat with `:VibingChat`
- Tools work normally in new session

**Solution 3:** Temporary bypass

```
/permission bypassPermissions
```

(Use with caution - disables all permission checks)

## Test Coverage

### Unit Tests

**File:** `tests/permission-logic.test.mjs`

**Coverage:**

- Simple tool name matching
- Bash wildcard patterns (`npm:*`, `git:*`)
- Bash exact command matching
- Pattern parsing and validation

**Example Test:**

```javascript
// Test 1: Simple tool name match
const result1 = matchesPermission('Bash', { command: 'npm install' }, 'Bash');
console.assert(result1 === true, 'Test 1 failed');

// Test 2: Bash wildcard match
const result2 = matchesPermission('Bash', { command: 'npm install' }, 'Bash(npm:*)');
console.assert(result2 === true, 'Test 2 failed');

// Test 3: Bash wildcard non-match
const result3 = matchesPermission('Bash', { command: 'ls' }, 'Bash(npm:*)');
console.assert(result3 === false, 'Test 3 failed');
```

### Integration Tests

**File:** `tests/chat_init_spec.lua`

**Coverage:**

- `/ask` command registration
- Command count verification (13 total commands including `/ask`)
- Frontmatter parsing with `permissions_ask` field

### Manual Test Scenarios

1. **Basic Ask Functionality:**
   - Add tool to ask list: `/ask Bash`
   - Execute tool → approval prompt appears
   - Approve → tool executes
   - Deny → tool blocked

2. **Granular Pattern:**
   - Add pattern: `/ask Bash(git:*)`
   - Execute git command → approval prompt
   - Execute npm command → no prompt (not matched)

3. **Allow Override:**
   - Add to both lists: `/ask Bash` then `/allow Bash`
   - Execute Bash → auto-approved (no prompt)
   - Notification shown about override

4. **Resume Session:**
   - Add to ask list: `/ask Bash`
   - Close and reopen chat (resume session)
   - Execute Bash → denied with helpful message

## Limitations and Known Issues

### 1. Ask-listed Tools Denied in Resume Sessions

**Cause:** Agent SDK Issue #29 - `canUseTool` callback is bypassed in resumed sessions.

**Impact:** Users cannot use ask-listed tools when reopening saved chats.

**Workarounds:**

- Add to allow list (`/allow`)
- Start new session (`:VibingChat` without file argument)
- Temporarily bypass permissions (`/permission bypassPermissions`)

**Status:** No SDK fix available as of version 0.1.76.

### 2. Pattern Matching Complexity

**Issue:** Users must understand pattern syntax for effective use.

**Mitigation:**

- Help text shown on validation errors
- Examples in `/allow`, `/deny`, `/ask` command feedback
- Documentation in CLAUDE.md

### 3. No Persistent Ask History

**Issue:** Each ask prompt requires fresh approval - no "remember this session" option.

**Rationale:** Security-first design - explicit approval for each use.

**Future Enhancement:** Could add per-session approval cache.

## Future Enhancements

### 1. Session-scoped Approval Cache

Allow users to approve once per session:

```
Tool Bash requires approval. Allow for:
  [ ] This operation only
  [x] All operations this session
  [ ] Always (add to allow list)
```

### 2. Approval Templates

Pre-defined approval patterns:

```
/ask-template safe-dev
  → Adds: Bash(npm:*), Bash(git:*), Read(src/**/*), Write(*.json)
```

### 3. Visual Pattern Builder

Interactive UI for building complex patterns:

```
/pattern-builder Bash
  → Opens picker:
     Command prefix: [git    ]
     Arguments:      [commit ]
     Match type:     [Wildcard args (*)]
     → Generates: Bash(git commit:*)
```

### 4. Issue #29 Resolution

If Agent SDK fixes Issue #29 in future versions:

- Remove resume session workaround (lines 605-614 in agent-wrapper.mjs)
- Update user documentation
- Add integration tests for resume session ask behavior

## References

- ADR 001: Permissions Ask Implementation and Agent SDK Constraints
- Issue #174: Add "ask" permission tier alongside allow/deny
- Agent SDK Issue #29: https://github.com/anthropics/claude-agent-sdk-typescript/issues/29
- Implementation: bin/agent-wrapper.mjs (lines 417-700)
- Tests: tests/permission-logic.test.mjs
- Chat history: .vibing/chat/permissions-ask-sdk-constraints-investigation.vibing
