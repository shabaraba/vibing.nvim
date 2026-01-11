# Buffer Change Detection Phase 2 Testing Guide

This document describes how to test the Phase 2 implementation of buffer change detection and multi-agent coordination, which includes full ChatBuffer integration.

## Prerequisites

- vibing.nvim installed and configured
- Neovim with Lua support

## Phase 2 Features

Phase 2 adds the following features to the PoC:

1. **ChatBuffer Integration**: Chat sessions automatically support shared buffer communication
2. **Slash Commands**: Easy-to-use commands for shared buffer operations
3. **Automatic Registration**: Sessions can opt-in to shared buffer system
4. **Real-time Notifications**: Receive notifications when mentioned by other Claude sessions

## New Slash Commands

| Command            | Description                                      | Example                                    |
| ------------------ | ------------------------------------------------ | ------------------------------------------ |
| `/enable-shared`   | Enable shared buffer integration for this chat   | `/enable-shared`                           |
| `/disable-shared`  | Disable shared buffer integration                | `/disable-shared`                          |
| `/shared [pos]`    | Open shared buffer                               | `/shared`, `/shared right`, `/shared float` |
| `/post <msg> [@]`  | Post message to shared buffer with mentions      | `/post Review please @Claude-abc12`       |

## Testing Scenarios

### Test 1: Basic Integration

**Goal**: Verify that chat sessions can enable shared buffer and receive a Claude ID.

**Steps**:

1. Start Neovim and open a chat:
   ```vim
   :VibingChat
   ```

2. Send a message to start a session:
   ```
   Hello
   ```

3. Enable shared buffer integration:
   ```
   /enable-shared
   ```

4. Verify that you receive a notification with your Claude ID (e.g., "Shared buffer enabled. You are Claude-abc12")

**Expected Result**: Session is registered with a unique Claude ID.

---

### Test 2: Two-Way Communication

**Goal**: Verify that two chat sessions can communicate through the shared buffer.

**Steps**:

1. **Session 1**:
   ```vim
   :VibingChat right
   ```
   Send "Hello" to initialize session, then:
   ```
   /enable-shared
   ```
   Note your Claude ID (e.g., Claude-abc12)

2. **Session 2**:
   ```vim
   :VibingChat left
   ```
   Send "Hello" to initialize session, then:
   ```
   /enable-shared
   ```
   Note your Claude ID (e.g., Claude-def34)

3. **From Session 1**, post a message mentioning Session 2:
   ```
   /post Task completed @Claude-def34
   ```

4. **Session 2** should receive a notification

5. **From Session 2**, reply:
   ```
   /post Thanks! @Claude-abc12
   ```

6. **Session 1** should receive a notification

**Expected Result**: Both sessions can send and receive notifications.

---

### Test 3: Shared Buffer View

**Goal**: Verify that the shared buffer displays all messages correctly.

**Steps**:

1. Set up two sessions with `/enable-shared` (see Test 2)

2. From one session, open the shared buffer:
   ```
   /shared float
   ```

3. Post messages from both sessions:
   ```
   Session 1: /post Starting backend work @All
   Session 2: /post Starting frontend work @All
   ```

4. Check the shared buffer content - it should show:
   ```markdown
   ## 2026-01-11 18:00:00 Claude-abc12

   Starting backend work @All

   ## 2026-01-11 18:01:00 Claude-def34

   Starting frontend work @All
   ```

**Expected Result**: All messages are visible in the shared buffer with proper formatting.

---

### Test 4: Multiple Mentions

**Goal**: Verify that @All works correctly.

**Steps**:

1. Set up three chat sessions:
   - Session 1 (right split): `/enable-shared`
   - Session 2 (left split): `/enable-shared`
   - Session 3 (float): `/enable-shared`

2. From Session 1, post with @All:
   ```
   /post Need help with testing @All
   ```

3. Verify that Sessions 2 and 3 receive notifications

4. Verify that Session 1 does NOT receive its own notification

**Expected Result**: All other sessions receive notification except the sender.

---

### Test 5: Disable/Re-enable

**Goal**: Verify that disabling/re-enabling works correctly.

**Steps**:

1. Set up two sessions with `/enable-shared`

2. From Session 1:
   ```
   /post Test message @Claude-{session2-id}
   ```

3. Verify Session 2 receives notification

4. From Session 2:
   ```
   /disable-shared
   ```

5. From Session 1:
   ```
   /post Another message @Claude-{session2-id}
   ```

6. Verify Session 2 does NOT receive notification

7. From Session 2:
   ```
   /enable-shared
   ```

8. From Session 1:
   ```
   /post Final message @Claude-{session2-id}
   ```

9. Verify Session 2 receives notification again

**Expected Result**: Sessions only receive notifications when enabled.

---

### Test 6: Session Persistence

**Goal**: Verify that shared buffer integration persists across session saves/loads.

**Steps**:

1. Open a chat, initialize session, and enable shared buffer:
   ```
   /enable-shared
   ```

2. Save the chat:
   ```
   /save
   ```

3. Note the file path (e.g., `~/.local/share/nvim/vibing/chats/chat-20260111-180000.vibing`)

4. Close the chat window:
   ```vim
   :q
   ```

5. Reopen the saved chat:
   ```vim
   :VibingChat ~/.local/share/nvim/vibing/chats/chat-20260111-180000.vibing
   ```

6. Check if shared buffer is still enabled (try posting a message)

**Expected Result**: Currently, shared buffer integration does NOT persist (expected limitation in Phase 2).

**Future Work**: Add `shared_buffer_enabled: true` to frontmatter to persist state.

---

## Manual Testing Checklist

- [ ] `/enable-shared` registers session
- [ ] `/disable-shared` unregisters session
- [ ] `/shared` opens shared buffer in correct position
- [ ] `/post` sends message to shared buffer
- [ ] `@Claude-{id}` triggers notification to specific session
- [ ] `@All` triggers notifications to all sessions except sender
- [ ] Notifications display correctly via vim.notify
- [ ] Closing chat window unregisters from shared buffer
- [ ] Multiple concurrent sessions work without conflicts
- [ ] `/help` shows shared buffer commands

## Known Issues and Limitations (Phase 2)

1. **No Persistence**: `_shared_buffer_enabled` state is not saved to frontmatter
2. **No Auto-Response**: Notifications are display-only; no automatic replies
3. **Single Shared Buffer**: Only one global shared buffer is supported
4. **No History Search**: Can't search notification history
5. **Manual Claude ID Lookup**: Must manually note other sessions' Claude IDs

## Debugging

### Check Registered Sessions

```vim
:VibingListSessions
```

This will show all currently registered Claude sessions with their IDs and buffer numbers.

### Check Shared Buffer Content

```vim
:VibingShared float
```

Open the shared buffer to see all posted messages.

### Check Watcher Status

```lua
:lua vim.print(require('vibing.core.buffer_watcher').get_watched_buffers())
```

This shows which buffers are currently being watched for changes.

### Enable Debug Logging

```lua
:lua vim.notify("Test notification", vim.log.levels.DEBUG)
```

## Reporting Issues

If you encounter bugs during testing:

1. Note the exact steps to reproduce
2. Check `:messages` for error logs
3. Run `:VibingListSessions` to check registration state
4. Open a GitHub issue with:
   - Neovim version (`:version`)
   - vibing.nvim version/commit
   - Minimal reproduction steps
   - Expected vs actual behavior

## Next Steps (Phase 3)

After Phase 2 testing is complete, the following enhancements are planned:

1. **Frontmatter Persistence**: Save `shared_buffer_enabled` state
2. **Auto-Response**: AI decides whether to respond to mentions
3. **Rich Notifications**: In-buffer indicators, highlights
4. **Multiple Shared Buffers**: Per-project or per-topic buffers
5. **History Search**: Search past notifications and messages
