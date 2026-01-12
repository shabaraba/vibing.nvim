# Mention-Driven Task Interruption

**Status:** Experimental / Phase 2.5 Feature (canToolUse Integration Complete)

This document describes the mention-driven task interruption feature, which ensures that Claude sessions respond to mentions before continuing with other tasks.

## Key Feature: Real-Time Interruption

**This feature uses canToolUse callback to interrupt Claude immediately when tool execution is attempted**, ensuring mentions are handled even during long-running tasks. This is superior to message-send blocking alone.

## Overview

When a Claude session receives a mention from another session via the shared buffer, it should acknowledge and respond before proceeding with tool executions. This feature implements an interruption mechanism that:

1. **Blocks tool execution** when there are unprocessed mentions
2. **Notifies the user** about pending mentions
3. **Resumes work** after the user acknowledges/responds to mentions

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ canToolUse Interruption Flow (Real-Time)                │
│                                                          │
│  Claude is executing tools...                           │
│     ↓                                                   │
│  Tool about to execute (e.g., Read, Edit, Bash)         │
│     ↓                                                   │
│  canUseTool callback invoked (agent-wrapper)            │
│     ↓                                                   │
│  Check unprocessed mentions via MCP                     │
│     │                                                   │
│     ├─ mcp__vibing-nvim__nvim_has_unprocessed_mentions  │
│     └─ mcp__vibing-nvim__nvim_get_unprocessed_mentions  │
│     ↓                                                   │
│  Has mentions?                                          │
│     ↓                                                   │
│  4a. YES → Deny tool execution                          │
│     - Return deny with mention details                  │
│     - Claude pauses work immediately                    │
│     - User sees: "You have N unprocessed mentions"      │
│     - User runs: /check-mentions                        │
│     - Mentions marked as processed                      │
│     - User re-sends message → Work resumes              │
│                                                          │
│  4b. NO → Allow tool execution                          │
│     - Tool executes normally                            │
│     - Work continues                                    │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Mention Tracking System                                 │
│                                                          │
│  MentionTracker                                         │
│  ├─ record_mention(claude_id, message)                  │
│  ├─ get_unprocessed_mentions(claude_id)                 │
│  ├─ mark_processed(claude_id, message_id)               │
│  └─ mark_all_processed(claude_id)                       │
│                                                          │
│  Storage: mention_history[claude_id][message_id]        │
│  {                                                       │
│    message_id: "timestamp-from_id",                     │
│    timestamp: "2026-01-11 18:00:00",                    │
│    from_claude_id: "abc12",                             │
│    content: "Message content",                          │
│    processed: false                                     │
│  }                                                       │
└─────────────────────────────────────────────────────────┘
```

## Components

### 1. MentionTracker

**File:** `lua/vibing/application/shared_buffer/mention_tracker.lua`

Tracks processed and unprocessed mentions for each Claude session.

**Key Methods:**
- `record_mention(claude_id, message)` - Record a new mention
- `get_unprocessed_mentions(claude_id)` - Get all unprocessed mentions
- `mark_processed(claude_id, message_id)` - Mark specific mention as processed
- `mark_all_processed(claude_id)` - Mark all mentions as processed
- `get_summary(claude_id)` - Get mention statistics

### 2. ChatBuffer Integration

**File:** `lua/vibing/presentation/chat/buffer.lua`

Extended ChatBuffer with mention tracking:

**New Methods:**
- `has_unprocessed_mentions()` - Check if there are unprocessed mentions
- `get_unprocessed_mentions()` - Get list of unprocessed mentions
- `mark_all_mentions_processed()` - Mark all as processed
- `mark_mention_processed(message_id)` - Mark specific mention as processed

**Modified Methods:**
- `send_message()` - Blocks if unprocessed mentions exist
- `_on_shared_buffer_notification(message)` - Records mentions automatically

### 3. MCP Tools for Mention Checking

**Tools:**
- `mcp__vibing-nvim__nvim_has_unprocessed_mentions` - Check if mentions exist
- `mcp__vibing-nvim__nvim_get_unprocessed_mentions` - Get mention details

**Files:**
- `mcp-server/src/handlers/shared_buffer.ts` - MCP handlers
- `lua/vibing/infrastructure/rpc/handlers/shared_buffer.lua` - RPC handlers
- `lua/vibing/presentation/chat/controller.lua` - `get_active_chat_buffer()` method

These tools allow Agent SDK's canUseTool callback to query mention status in real-time.

### 4. canUseTool Integration

**File:** `bin/lib/permissions/can-use-tool.ts`

The `createCanUseToolCallback()` function now checks for unprocessed mentions **before every tool execution**. If mentions exist, it returns `deny` with a descriptive message, immediately interrupting Claude's work.

**Flow:**
1. Tool about to execute (e.g., `Read`, `Edit`, `Bash`)
2. canUseTool callback invoked
3. MCP call: `nvim_has_unprocessed_mentions()`
4. If mentions exist → `deny` with message listing mentions
5. If no mentions → `allow` tool execution

### 5. Slash Command

**Command:** `/check-mentions`

**File:** `lua/vibing/application/chat/handlers/check_mentions.lua`

Displays all unprocessed mentions and marks them as processed.

## User Workflow

### Scenario: Interruption by Mention

1. **Claude-abc12** is working on a task (e.g., writing code)
2. **Claude-def34** mentions Claude-abc12:
   ```
   /post Need help with authentication @Claude-abc12
   ```
3. **Claude-abc12** receives notification (stored as unprocessed)
4. **Claude-abc12** tries to send next message → **BLOCKED**:
   ```
   [WARN] You have 1 unprocessed mention(s). Use /check-mentions to review them before continuing.
     - 2026-01-11 18:00:00 from Claude-def34
   ```
5. **Claude-abc12** checks mentions:
   ```
   /check-mentions
   ```
   Output:
   ```
   You have 1 unprocessed mention(s):
     [1] 2026-01-11 18:00:00 from Claude-def34: ## 2026-01-11 18:00:00 Claude-def34
   All mentions marked as processed
   ```
6. **Claude-abc12** responds to Claude-def34:
   ```
   /post I can help with that. Let me review the code. @Claude-def34
   ```
7. **Claude-abc12** can now continue with original work

## Usage Examples

### Example 1: Two Agents Collaborating

**Session 1 (Claude-abc12):**
```
User: Write a login function

Claude: I'll implement the login function...

[At this point, Claude-def34 sends a mention]

[WARN] You have 1 unprocessed mention(s). Use /check-mentions to review them before continuing.
  - 2026-01-11 18:00:00 from Claude-def34

User: /check-mentions

[Shows: "Review the security of my login function @Claude-abc12"]

User: /post I'll review it right after finishing mine. @Claude-def34

User: [Now can continue with original task]
```

**Session 2 (Claude-def34):**
```
User: Write authentication middleware

Claude: [working...]

[Sends mention to Claude-abc12]

User: /post Review the security of my login function @Claude-abc12

[Continues working...]

[Later receives response from Claude-abc12]
```

### Example 2: Broadcast Mention

**Session 1 (Claude-abc12):**
```
User: /post Emergency: Found security vulnerability in auth module @All

[Continue working on fix]
```

**Session 2 (Claude-def34) & Session 3 (Claude-xyz56):**
```
[Both receive mention]

[Try to send message → BLOCKED]

/check-mentions

[Acknowledge and respond if needed]
```

## Configuration

No additional configuration needed. The feature automatically activates when:
1. Shared buffer integration is enabled (`/enable-shared`)
2. A mention is received from another Claude session

## Commands

| Command          | Description                                      |
| ---------------- | ------------------------------------------------ |
| `/check-mentions` | View and clear all unprocessed mentions         |

## Implementation Details

### Mention Recording

Mentions are automatically recorded when `_on_shared_buffer_notification()` is called:

```lua
function ChatBuffer:_on_shared_buffer_notification(message)
  local MentionTracker = require("vibing.application.shared_buffer.mention_tracker")
  if self._claude_id then
    MentionTracker.record_mention(self._claude_id, message)
  end
  -- ... display notification
end
```

### canToolUse Integration (Primary Mechanism)

**File:** `bin/lib/permissions/can-use-tool.ts`

Every tool execution checks for mentions via MCP:

```typescript
// Before every tool execution
if (mcpEnabled) {
  const mentionCheckResult = await use_mcp_tool(
    'vibing-nvim',
    'nvim_has_unprocessed_mentions',
    {}
  );

  if (mentionCheckResult && mentionCheckResult.has_mentions) {
    // Get details
    const mentionsResult = await use_mcp_tool(
      'vibing-nvim',
      'nvim_get_unprocessed_mentions',
      {}
    );

    // Return deny with mention summary
    return {
      behavior: 'deny',
      message: `You have ${mentionCheckResult.count} unprocessed mention(s)...`
    };
  }
}

// Allow tool if no mentions
return { behavior: 'allow', updatedInput: input };
```

**Key Benefits:**
- **Immediate interruption** during long-running tasks
- **No polling required** - checks happen naturally during tool use
- **Graceful error handling** - failures don't block work

### MCP Tool Implementation

**TypeScript (mcp-server/src/handlers/shared_buffer.ts):**

```typescript
export async function handleHasUnprocessedMentions(args: { rpc_port?: number }) {
  const result = await callNeovim('has_unprocessed_mentions', {}, rpcPort);
  return result;
}
```

**Lua (lua/vibing/infrastructure/rpc/handlers/shared_buffer.lua):**

```lua
function M.has_unprocessed_mentions(params)
  local chat_buffer = chat_controller.get_active_chat_buffer()
  if not chat_buffer then
    return { has_mentions = false, count = 0 }
  end

  local has_mentions = chat_buffer:has_unprocessed_mentions()
  local mentions = chat_buffer:get_unprocessed_mentions()

  return {
    has_mentions = has_mentions,
    count = #mentions,
    claude_id = chat_buffer:get_claude_id(),
  }
end
```

### Mention Processing

User clears mentions with `/check-mentions`:

```lua
-- Display all unprocessed mentions
for i, mention in ipairs(mentions) do
  print(string.format("  [%d] %s from Claude-%s: %s", ...))
end

-- Mark all as processed
chat_buffer:mark_all_mentions_processed()
```

## Limitations

1. **No Automatic Resume**: After processing mentions, user must manually send message again
2. **All-or-Nothing**: `/check-mentions` marks ALL mentions as processed (no selective processing)
3. **No Priority**: All mentions are treated equally (no urgent/normal distinction)
4. **No Timeout**: Mentions don't expire (remain unprocessed until acknowledged)

## Future Enhancements

1. **Selective Processing**: Mark specific mentions as processed
2. **Priority Levels**: Urgent mentions could force immediate attention
3. **Automatic Resume**: Automatically retry blocked operation after processing mentions
4. **Mention Expiry**: Auto-process mentions after timeout
5. **Rich Display**: Show mention content in popup window instead of print()
6. **Response Templates**: Quick response options for common scenarios

## Testing

See [buffer-change-detection-phase2-testing.md](buffer-change-detection-phase2-testing.md) for comprehensive testing guide.

### Quick Test

1. Open two chat sessions and enable shared buffer:
   ```
   :VibingChat right
   :VibingChat left

   # In both:
   Hello
   /enable-shared
   ```

2. From Session 1, send mention:
   ```
   /post Test mention @Claude-{session2-id}
   ```

3. In Session 2, try to send a message:
   ```
   Any message here
   [Press Enter]
   ```

   **Expected**: Message is blocked with warning

4. Check mentions:
   ```
   /check-mentions
   ```

   **Expected**: Shows mention from Session 1, marks as processed

5. Send message again:
   ```
   Any message here
   [Press Enter]
   ```

   **Expected**: Message sends successfully

## Debugging

### Check Mention History

```lua
:lua vim.print(require('vibing.application.shared_buffer.mention_tracker').get_history('Claude-abc12'))
```

### Check Summary

```lua
:lua vim.print(require('vibing.application.shared_buffer.mention_tracker').get_summary('Claude-abc12'))
```

Output:
```
{
  total = 5,
  processed = 3,
  unprocessed = 2
}
```

### Clear History (Testing)

```lua
:lua require('vibing.application.shared_buffer.mention_tracker').clear_history()
```

## Known Issues

1. **No State Persistence**: Mention history is lost when Neovim restarts
2. **Memory Growth**: Mention history grows unbounded (no automatic cleanup)
3. **No Cross-Session Sync**: Each Neovim instance has separate mention history

## References

- [ADR 008: Buffer Change Detection](adr/008-buffer-change-detection-multi-agent.md)
- [Buffer Change Detection PoC](buffer-change-detection-poc.md)
- [Phase 2 Testing Guide](buffer-change-detection-phase2-testing.md)
