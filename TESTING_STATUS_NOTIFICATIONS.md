# Status Notifications Testing Guide

## Overview

This document provides testing instructions for the status notification system implemented for issue #168.

## Implementation Summary

### Architecture

- **StatusManager**: Centralized state management for Claude's turn states
- **State Machine**: idle → thinking → tool_use → responding → done
- **Display Methods**: noice.nvim (priority) with vim.notify fallback
- **Scope**: Both chat and inline actions

### Modified Files

1. `lua/vibing/status_manager.lua` (NEW) - Core status management module
2. `bin/agent-wrapper.mjs` - Enhanced to emit status messages
3. `lua/vibing/adapters/agent_sdk.lua` - Status message handling
4. `lua/vibing/actions/chat.lua` - StatusManager integration for chat
5. `lua/vibing/actions/inline.lua` - StatusManager integration for inline (replaces InlineProgress)
6. `lua/vibing/ui/chat_buffer.lua` - Removed duplicate spinner logic
7. `lua/vibing/config.lua` - Added status configuration

## Configuration

Default configuration (in `lua/vibing/config.lua`):

```lua
status = {
  enable = true,                -- Enable status notifications
  show_tool_details = true,     -- Show tool input details (file names, etc.)
  auto_dismiss_timeout = 2000,  -- Auto-dismiss "Done" notification after 2s
}
```

**Implementation:**

- Uses `vim.notify()` for all notifications
- Automatic deduplication: duplicate messages are skipped
- Only displays notifications when the status message changes
- Spinner animation using Braille characters: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏

## Manual Testing Checklist

### 1. Basic Functionality

**Setup:**

```lua
require("vibing").setup({
  status = {
    enable = true,
    show_tool_details = true,
    auto_dismiss_timeout = 2000,
  },
})
```

**Test Cases:**

- [ ] Open chat: `:VibingChat`
- [ ] Send a simple message
- [ ] Verify status progression:
  - [ ] "⠋ 思考中..." appears with spinner animation
  - [ ] "⏺ Running Edit(file.lua)" appears when Claude edits a file
  - [ ] "✓ Responding..." appears when Claude starts responding
  - [ ] "✓ Done (N files modified)" appears and auto-dismisses after 2s

**Expected Behavior:**

- Notifications appear via `vim.notify()`
- Spinner animates through Braille characters: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
- Tool details show file names when `show_tool_details = true`
- **Duplicate messages are skipped** - same notification won't appear multiple times

### 2. Inline Action Integration

**Test Cases:**

- [ ] Open a file and visually select some code
- [ ] Run: `:'<,'>VibingInline fix`
- [ ] Verify status notifications appear similarly to chat
- [ ] Verify action_type is "inline" in notification title

**Expected Behavior:**

- Same status progression as chat
- Title shows "[vibing] Inline" instead of "[vibing] Chat"

### 3. Tool Detail Display

**Test with `show_tool_details = true`:**

- [ ] Verify Edit shows: "⏺ Running Edit(lua/vibing/config.lua)"
- [ ] Verify Write shows: "⏺ Running Write(new_file.lua)"
- [ ] Verify Read shows: "⏺ Running Read(README.md)"
- [ ] Verify Bash shows: "⏺ Running Bash(npm install)"

**Test with `show_tool_details = false`:**

- [ ] Verify all tools show: "⏺ Running Edit" (no file name)

### 4. Error Handling

**Test Case:**

- [ ] Trigger an error (e.g., invalid API key, network issue)
- [ ] Verify error notification appears with ERROR level
- [ ] Verify spinner stops on error

### 5. Configuration Toggles

**Test `enable = false`:**

```lua
require("vibing").setup({
  status = { enable = false },
})
```

- [ ] Verify no status notifications appear
- [ ] Verify functionality still works (just no notifications)

**Test `auto_dismiss_timeout`:**

```lua
require("vibing").setup({
  status = { auto_dismiss_timeout = 5000 },  -- 5 seconds
})
```

- [ ] Verify "Done" notification stays for 5 seconds before dismissing

### 6. State Transitions

**Complete State Flow:**

1. [ ] **idle** → (user sends message)
2. [ ] **thinking** → "⠋ 思考中..."
3. [ ] **tool_use** → "⏺ Running Edit(...)"
4. [ ] **thinking** → "⠋ 思考中..." (after tool completion)
5. [ ] **tool_use** → "⏺ Running Write(...)" (if multiple tools)
6. [ ] **responding** → "✓ Responding..."
7. [ ] **done** → "✓ Done (2 files modified)"
8. [ ] **idle** → (auto-dismissed after timeout)

### 7. Multiple Tool Execution

**Test Case:**

- [ ] Ask Claude to create multiple files
- [ ] Verify status updates for each tool:
  - "⏺ Running Write(file1.lua)"
  - "⏺ Running Write(file2.lua)"
  - "⏺ Running Edit(file3.lua)"
- [ ] Verify final "Done" shows correct file count

### 8. Session Resumption

**Test Case:**

- [ ] Save a chat with `:w test.vibing`
- [ ] Close and reopen: `:e test.vibing`
- [ ] Send a new message
- [ ] Verify status notifications still work

## Code Verification

### StatusManager Module

```bash
# Check syntax
nvim --headless -c "luafile lua/vibing/status_manager.lua" -c "qa"
```

### Agent Wrapper

```bash
# Check Node.js syntax
node --check bin/agent-wrapper.mjs
```

## Integration Points

### 1. Agent Wrapper → Adapter

- **Emits**: `{ type: "status", state: "thinking|tool_use|responding" }`
- **Handler**: `lua/vibing/adapters/agent_sdk.lua:180-190`

### 2. Adapter → StatusManager

- **Calls**: `status_manager:set_thinking()`, `set_tool_use()`, `set_responding()`
- **Location**: `lua/vibing/adapters/agent_sdk.lua:182-189`

### 3. Chat/Inline → StatusManager

- **Creates**: `StatusManager:new(config.status)`
- **Passes**: `opts.status_manager = status_mgr`
- **Location**: `lua/vibing/actions/chat.lua:167-169`, `lua/vibing/actions/inline.lua:154-155`

### 4. StatusManager → vim.notify

- **Implementation**: Uses `vim.notify()` for all notifications
- **Deduplication**: `_last_message` field tracks previous message, skips duplicates
- **Location**: `lua/vibing/status_manager.lua:213-239`

## Known Issues / Limitations

1. **New notification per change**: Creates new notification when message changes (no in-place update)
2. **Spinner animation**: Braille spinner updates every 100ms for visual feedback
3. **Auto-dismiss**: Only applies to "Done" state, not error state
4. **Deduplication**: Same message won't trigger notification, preventing spam

## Troubleshooting

### No notifications appear

- Check: `status.enable = true` in config
- Check: No Lua errors in `:messages`
- Check: StatusManager module loads: `:lua require("vibing.status_manager")`
- Check: vim.notify is working: `:lua vim.notify("Test", vim.log.levels.INFO)`

### Spinner doesn't animate

- Check: Timer is created (spinner updates every 100ms)
- Check: State is "thinking" or "tool_use" (spinner only shows during active states)
- Debug: Add print statements in `_start_spinner()` to verify timer creation

### Tool details not showing

- Check: `status.show_tool_details = true` in config
- Check: Agent wrapper emits `input_summary` in status messages
- Check: Tool has input summary (not all tools provide detailed input)

### Duplicate notifications appearing

- This should not happen with the current implementation
- Check: `_last_message` is properly tracking previous messages
- Debug: Check if multiple StatusManager instances are being created

## Success Criteria

✅ All test cases pass
✅ Status notifications appear and update correctly
✅ vim.notify displays all state transitions
✅ Deduplication prevents duplicate notifications
✅ Both chat and inline actions show status
✅ Configuration options work as expected
✅ No regressions in existing functionality
✅ Error handling works correctly
✅ Spinner animation works smoothly
✅ No spam from repeated tool executions

## Next Steps After Testing

If all tests pass:

1. Update documentation (README.md) with status notification feature
2. Create demo GIF/video showing the feature in action
3. Close issue #168
4. Consider additional enhancements:
   - Customizable status messages
   - More granular tool categories
   - Status history/log viewer
