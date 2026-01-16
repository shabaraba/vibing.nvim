---
name: squad-mention
description: Guide for Squad-to-Squad mention-based autonomous communication in vibing.nvim. Use when needing to collaborate with other Squads or when receiving mentions from other agents.
---

# Squad Mention Communication Guide

This skill explains how to communicate with other Squads (Claude agents) in vibing.nvim using the mention system.

## Core Concept

**Squads communicate autonomously through mentions - NO USER INTERVENTION required.**

When you want to collaborate with another Squad:
1. Write `@SquadName` in YOUR buffer
2. Include full context and instructions
3. End your response (done)
4. vibing.nvim automatically detects and delivers the message

## Sending Mentions

### How to Send

Simply write a message starting with `@SquadName` in your own response:

```markdown
## Assistant <YourSquadName>

@Alpha I need your help with LSP analysis.

Could you analyze the `lua/vibing/init.lua` file and tell me:
1. What are the main responsibilities?
2. How does the command registration work?
3. What is the initialization flow?

Please report back to me when done.
```

### What Happens Next

1. **You finish your response** - Your message is complete, you send `done`
2. **vibing.nvim detects the mention** - Lua/TypeScript code parses your buffer
3. **Message is delivered** - The mention appears in Alpha's buffer as:
   ```markdown
   ## Mention from <YourSquadName> <!-- timestamp -->

   Received mention from YourSquadName (buffer X):

   I need your help with LSP analysis...
   ```
4. **Alpha is notified** - If Alpha is idle, they receive the mention immediately. If busy, they receive an interruption via `canUseTool`

### Best Practices for Sending

✅ **DO:**
- Provide sufficient context - explain what you're working on
- Be specific about what you need
- Include all relevant information (file paths, error messages, requirements)
- Specify expected deliverable format

❌ **DON'T:**
- Send vague requests like "@Alpha help" or "@Alpha check this"
- Assume the other Squad knows your current context
- Try to use MCP tools to manually send messages

### Good Example

```markdown
@Alpha I'm implementing a new permission rule system for vibing.nvim.

**Task:** Please analyze the current permission system in `bin/lib/permissions/`

**What I need:**
1. List all permission-related files and their responsibilities
2. Identify how rules are currently evaluated
3. Suggest where to add the new "domain" permission rule

**Context:** User wants to allow/deny web tools based on domain patterns (e.g., allow github.com, deny *.ads.com)

Please report your findings back to me when complete.
```

### Bad Example (Avoid)

```markdown
@Alpha check the permission code
```

## Receiving Mentions

### How Mentions Appear

When another Squad mentions you, it appears in your buffer as:

```markdown
## Mention from <SenderSquadName> <!-- timestamp -->

Received mention from SenderSquadName (buffer X):

[Full message content from sender]
```

**How to reply:** Simply write `@SenderSquadName` in YOUR response with your reply. vibing.nvim will automatically deliver it.

### How to Respond

**Method 1: Mention Back (Recommended)**

Simply write `@SenderSquadName` in YOUR response:

```markdown
## Assistant <YourSquadName>

@Commander Analysis complete!

I've reviewed the permission system. Here are my findings:

**Files:**
1. `can-use-tool.ts` - Main permission checker
2. `rule-matcher.ts` - Rule evaluation logic
3. `types.ts` - Type definitions

**Current Evaluation:**
Rules are evaluated in order: deny first, then allow.

**Suggestion:**
Add domain matching logic in `rule-matcher.ts`, function `matchesRule()`.

Let me know if you need more details!
```

Then end your response. vibing.nvim will automatically deliver it to Commander.

**Method 2: Progress Reports**

If the task takes time, send progress updates:

```markdown
@Commander Started analyzing the codebase...

I've identified 3 relevant files. Currently reading `can-use-tool.ts`.
Will report full findings shortly.
```

## Common Patterns

### Pattern 1: Delegating a Subtask

**Commander → Alpha:**
```markdown
@Alpha I'm working on feature X. I need you to handle subtask Y.

Please implement the helper function `validateDomain(url, patterns)` in `bin/lib/utils.ts`.

Requirements:
- Support wildcards (* and **)
- Return boolean
- Follow existing code style

Report back when done and all tests pass.
```

**Alpha → Commander:**
```markdown
@Commander Task complete!

I've implemented `validateDomain()` with the following features:
- Wildcard support (*.example.com, **.example.com)
- Test coverage (5 test cases)
- All tests passing ✓

The function is ready in `bin/lib/utils.ts`.
```

### Pattern 2: Asking for Review

**Alpha → Commander:**
```markdown
@Commander Could you review my implementation?

I've implemented the mention system in PR #123. Please check:
1. Architecture decisions (is DDD structure correct?)
2. Error handling (are edge cases covered?)
3. Test coverage (is it sufficient?)

Let me know if any changes are needed.
```

### Pattern 3: Collaborative Analysis

**Commander → Multiple Squads:**
```markdown
@Alpha Please analyze the Lua side of the mention system (lua/vibing/domain/mention/).

@Beta Please analyze the TypeScript side of the mention system (bin/lib/mention/).

Report your findings back to me, and I'll integrate them into a comprehensive overview.
```

## Technical Details

### How the Mention System Works

1. **Detection** - `Detector.detect_mentions_in_last_response(bufnr)` scans your last Assistant message
2. **Parsing** - Extracts lines starting with `@SquadName` until next header or end of section
3. **Storage** - `MentionUseCase.record_mention()` stores mention in memory
4. **Delivery** - `Notifier.notify_if_idle()` checks if target Squad is busy
   - If idle: Inserts mention into their buffer immediately
   - If busy: Queues mention and interrupts via `canUseTool` callback

### Interruption During Busy State

If the target Squad is executing a tool when your mention arrives:

1. Their next tool call is **denied** with an error message
2. Error message includes your mention content
3. They can read and respond to your mention
4. After responding, they continue their original task

This ensures urgent collaboration without blocking work.

### Environment Variables

When you're running in vibing.nvim:
- `VIBING_NVIM_CONTEXT=true` - You're in vibing.nvim
- `VIBING_NVIM_RPC_PORT=<port>` - Your Neovim instance port

Use the RPC port when calling vibing-nvim MCP tools.

## Common Mistakes and How to Avoid

### ❌ Mistake 1: Trying to Manually Send Messages

**Wrong (using internal MCP tools):**
```javascript
// Don't use internal tools directly
await mcp__vibing-nvim__nvim_chat_send_message({ ... });
```

**Right (natural mention in your response):**
```markdown
@Commander My reply here
```

Mentions are automatically detected and delivered by vibing.nvim. No manual tool calls needed.

### ❌ Mistake 2: Not Providing Context

**Wrong:**
```markdown
@Alpha help with the bug
```

**Right:**
```markdown
@Alpha I'm debugging a buffer synchronization issue.

**Bug:** When user opens multiple chat windows, buffer content gets mixed up.
**Location:** `lua/vibing/ui/chat_buffer.lua`, function `attach_to_buffer()`
**What I need:** LSP analysis to find all places where buffer numbers are used.

Please analyze and report potential causes.
```

### ❌ Mistake 3: Expecting Immediate Response

**Wrong:**
```markdown
@Alpha analyze this code

[immediately starts working on something else]
```

**Right:**
```markdown
@Alpha analyze this code and report back to me.

I'll wait for your findings before proceeding with the next step.

[ends response, waits for Alpha's reply]
```

## When to Use Mentions

Use mentions when:
- ✅ You need help with a subtask (code analysis, implementation, testing)
- ✅ You want another Squad to review your work
- ✅ Task requires specialized knowledge (e.g., Alpha for deep LSP analysis)
- ✅ Parallel work is beneficial (multiple Squads working on different parts)

Don't use mentions when:
- ❌ You can handle the task yourself
- ❌ Task is trivial and doesn't require collaboration
- ❌ User is asking you directly and expecting YOUR response

## Squad Roles (Example)

While Squads are interchangeable, they can specialize:

- **Commander** - Orchestration, high-level planning, user interaction
- **Alpha** - Deep code analysis, LSP operations, research
- **Beta** - Implementation, testing, verification

You can establish roles dynamically based on task requirements.

## Summary

**Sending mentions:**
1. Write `@SquadName` with full context in YOUR buffer
2. End your response
3. vibing.nvim automatically delivers

**Receiving mentions:**
1. Read the mention in YOUR buffer
2. Understand the request
3. Do the work
4. Reply with `@SenderSquadName` in YOUR buffer
5. End your response

**No MCP tools needed. No user intervention. Fully autonomous Squad collaboration.**
