# Phase 3 State Persistence Testing Guide

**Feature:** Shared buffer configuration persists in chat frontmatter

**Status:** Ready for testing

## Overview

Phase 3 adds automatic state persistence so that when you enable shared buffer integration in a chat, this setting is saved to the chat file's frontmatter. When you reopen the chat later, the shared buffer integration is automatically restored.

## Test Cases

### Test 1: Basic State Persistence

**Objective:** Verify that `shared_buffer_enabled` is saved to frontmatter and restored on reload

**Steps:**

1. Open a new chat:
   ```vim
   :VibingChat
   ```

2. Send initial message to establish session:
   ```
   Hello
   ```

3. Enable shared buffer:
   ```
   /enable-shared
   ```

   **Expected:** Message appears: "Shared buffer enabled. You are Claude-{id}"

4. Save the chat:
   ```vim
   :w
   ```

5. Check frontmatter (should see `shared_buffer_enabled: true`):
   ```vim
   " Navigate to the top of the file and verify frontmatter
   gg
   ```

6. Close the chat:
   ```vim
   :q
   ```

7. Reopen the same chat file:
   ```vim
   :e path/to/chat-file.vibing
   ```

8. Send a test message to verify Claude is working:
   ```
   Are you still connected to the shared buffer?
   ```

**Expected Results:**
- ✅ Frontmatter contains `shared_buffer_enabled: true`
- ✅ When reopened, shared buffer is automatically enabled
- ✅ Claude ID is consistent (based on session_id)
- ✅ Can post messages with `/post` without re-enabling

---

### Test 2: Disable State Persistence

**Objective:** Verify that disabling shared buffer updates frontmatter to `false`

**Steps:**

1. Use the chat from Test 1 (with `shared_buffer_enabled: true`)

2. Disable shared buffer:
   ```
   /disable-shared
   ```

   **Expected:** Message appears: "Shared buffer disabled"

3. Save the chat:
   ```vim
   :w
   ```

4. Check frontmatter (should now see `shared_buffer_enabled: false`):
   ```vim
   gg
   ```

5. Close and reopen:
   ```vim
   :q
   :e path/to/chat-file.vibing
   ```

6. Try posting to shared buffer:
   ```
   /post Test message
   ```

**Expected Results:**
- ✅ Frontmatter updated to `shared_buffer_enabled: false`
- ✅ When reopened, shared buffer is NOT enabled
- ✅ `/post` command shows warning: "Shared buffer integration is not enabled"

---

### Test 3: Multi-Chat State Persistence

**Objective:** Verify that each chat maintains its own state independently

**Steps:**

1. Open Chat A:
   ```vim
   :VibingChat right
   ```
   ```
   Hello from Chat A
   /enable-shared
   ```
   Note the Claude ID (e.g., Claude-abc12)

2. Open Chat B:
   ```vim
   :VibingChat left
   ```
   ```
   Hello from Chat B
   " Do NOT enable shared buffer
   ```

3. Save both chats:
   ```vim
   " In Chat A window:
   :w

   " Switch to Chat B window (Ctrl-w h):
   :w
   ```

4. Close both chats and reopen:
   ```vim
   :qa
   :e path/to/chatA.vibing
   :vsplit path/to/chatB.vibing
   ```

5. Test posting from Chat A:
   ```
   /post Test from A
   ```

6. Try posting from Chat B:
   ```
   /post Test from B
   ```

**Expected Results:**
- ✅ Chat A: `shared_buffer_enabled: true` in frontmatter, can post
- ✅ Chat B: `shared_buffer_enabled: false` (or not present) in frontmatter, cannot post
- ✅ Each chat maintains independent state

---

### Test 4: Frontmatter Field Ordering

**Objective:** Verify that `shared_buffer_enabled` appears in proper position in frontmatter

**Steps:**

1. Create a new chat with full configuration:
   ```vim
   :VibingChat
   ```

2. Send initial message:
   ```
   Hello
   ```

3. Configure permissions:
   ```
   /permission acceptEdits
   /allow Read
   /allow Edit
   ```

4. Enable shared buffer:
   ```
   /enable-shared
   ```

5. Save and view frontmatter:
   ```vim
   :w
   gg
   ```

**Expected Frontmatter Order:**
```yaml
---
vibing.nvim: true
session_id: abc12345
created_at: 2026-01-12T10:00:00
mode: code
model: sonnet
permissions_mode: acceptEdits
permissions_allow:
  - Read
  - Edit
permissions_deny: []
language: ja
shared_buffer_enabled: true
---
```

**Expected Results:**
- ✅ `shared_buffer_enabled` appears after `language` field
- ✅ Field ordering matches priority defined in frontmatter.lua

---

### Test 5: Cross-Session Communication After Reload

**Objective:** Verify that reloaded sessions can communicate via shared buffer

**Steps:**

1. Open Chat A:
   ```vim
   :VibingChat right
   ```
   ```
   Hello from A
   /enable-shared
   ```
   Note Claude ID (e.g., Claude-abc12)
   ```vim
   :w
   ```

2. Open Chat B:
   ```vim
   :VibingChat left
   ```
   ```
   Hello from B
   /enable-shared
   ```
   Note Claude ID (e.g., Claude-def34)
   ```vim
   :w
   ```

3. Post from A to B:
   ```
   /post Testing mention @Claude-def34
   ```

4. Verify B received notification

5. Close both chats:
   ```vim
   :qa
   ```

6. Reopen both chats:
   ```vim
   :e path/to/chatA.vibing
   :vsplit path/to/chatB.vibing
   ```

7. Post from A to B again:
   ```
   /post Second mention after reload @Claude-def34
   ```

8. Check Chat B for notification

**Expected Results:**
- ✅ Both chats auto-reconnect to shared buffer on reload
- ✅ Claude IDs remain consistent (based on session_id)
- ✅ Mentions work correctly after reload
- ✅ Notifications appear in Chat B

---

## Edge Cases

### Edge Case 1: Chat Without Session ID

**Scenario:** Chat file has no session_id yet (freshly created, no messages sent)

**Steps:**
1. Create chat but don't send message
2. Try to enable shared buffer: `/enable-shared`

**Expected:** Shared buffer cannot be enabled without session_id (need to send at least one message first)

---

### Edge Case 2: Missing Frontmatter

**Scenario:** Chat file has no frontmatter block

**Steps:**
1. Create a .vibing file manually without frontmatter
2. Open it in Neovim
3. Try to enable shared buffer

**Expected:** System should handle gracefully, possibly create frontmatter

---

### Edge Case 3: Corrupted Frontmatter

**Scenario:** Frontmatter has invalid YAML

**Steps:**
1. Manually edit chat file with invalid YAML
2. Try to open and use shared buffer

**Expected:** System should handle gracefully without crashing

---

## Manual Verification Checklist

- [ ] `shared_buffer_enabled: true` appears in frontmatter after `/enable-shared`
- [ ] `shared_buffer_enabled: false` appears in frontmatter after `/disable-shared`
- [ ] Reopening chat with `true` auto-enables shared buffer
- [ ] Reopening chat with `false` keeps shared buffer disabled
- [ ] Field appears after `language` field in frontmatter
- [ ] Each chat maintains independent state
- [ ] Claude ID remains consistent across reload (based on session_id)
- [ ] Cross-session mentions work after reload
- [ ] No errors in `:messages` during reload

## Debug Commands

Check mention tracker state:
```lua
:lua vim.print(require('vibing.application.shared_buffer.mention_tracker').get_summary('Claude-abc12'))
```

Check notification dispatcher registry:
```lua
:lua vim.print(require('vibing.application.shared_buffer.notification_dispatcher').list_sessions())
```

View frontmatter:
```vim
:1,20p
```

## Regression Testing

After implementing Phase 3, verify these Phase 2/2.5 features still work:

- [ ] `/enable-shared` command works
- [ ] `/disable-shared` command works
- [ ] `/post` command works
- [ ] `/check-mentions` command works
- [ ] Mention interruption via canToolUse still works
- [ ] Notifications appear correctly
- [ ] Shared buffer window can be opened with `/shared`

## Known Issues

None reported yet.

## Notes

- State persistence only affects `shared_buffer_enabled` flag, not mention history
- Mention history is still in-memory only and cleared on Neovim restart
- If session_id changes (e.g., starting new conversation in same file), Claude ID will also change
