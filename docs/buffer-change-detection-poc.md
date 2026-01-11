# Buffer Change Detection PoC

**Status:** Experimental / Proof of Concept

This document describes the Proof of Concept (PoC) implementation for buffer change detection and multi-agent coordination in vibing.nvim.

## Overview

This feature enables multiple Claude sessions to communicate and coordinate through a shared buffer. Each session can:

- Post messages to a shared buffer
- Mention other Claude sessions using `@Claude-{id}`
- Broadcast to all sessions using `@All`
- Receive real-time notifications when mentioned

## Architecture

See [ADR 008: Buffer Change Detection for Multi-Agent Coordination](adr/008-buffer-change-detection-multi-agent.md) for detailed architecture.

## Quick Start

### 1. Run the Demo

The easiest way to see the feature in action:

```vim
:VibingSharedDemo
```

This will:
- Create a shared buffer
- Register 3 mock Claude sessions (Claude-abc12, Claude-def34, Claude-xyz56)
- Post sample messages with mentions
- Display notifications received by each session

### 2. Open the Shared Buffer

```vim
:VibingShared           " Open in right split (default)
:VibingShared current   " Open in current window
:VibingShared left      " Open in left split
:VibingShared float     " Open in floating window
```

### 3. View Registered Sessions

```vim
:VibingListSessions
```

This shows all currently registered Claude sessions.

## Usage

### Message Format

Messages in the shared buffer follow this format:

```markdown
## YYYY-MM-DD HH:MM:SS Claude-{id}

Message content here
```

### Mentioning Other Sessions

Use `@Claude-{id}` to mention a specific session or `@All` to notify everyone:

```markdown
## 2026-01-11 18:00:00 Claude-abc12

@Claude-def34 Could you review the login implementation?

## 2026-01-11 18:05:00 Claude-def34

@Claude-abc12 Sure, I'll take a look.

## 2026-01-11 18:10:00 Claude-xyz56

@All Let's sync up on the overall progress.
```

### Programmatic Usage

#### Creating a Shared Buffer

```lua
local SharedBufferManager = require("vibing.application.shared_buffer.manager")
local bufnr = SharedBufferManager.get_or_create_shared_buffer()
```

#### Registering a Session

```lua
local NotificationDispatcher = require("vibing.application.shared_buffer.notification_dispatcher")

NotificationDispatcher.register_session(
  "Claude-abc12",  -- Claude ID
  "session-123",   -- Session ID
  bufnr,           -- Buffer number
  function(message)
    -- Handle notification
    print("Received message from", message.from_claude_id)
  end
)
```

#### Posting a Message

```lua
local SharedBufferManager = require("vibing.application.shared_buffer.manager")

SharedBufferManager.append_message(
  "abc12",                    -- Your Claude ID
  "Implementation complete",  -- Content
  { "Claude-def34" }         -- Mentions (optional)
)
```

#### Parsing Messages

```lua
local MessageParser = require("vibing.application.shared_buffer.message_parser")

-- Parse buffer
local messages = MessageParser.parse_buffer(bufnr)

-- Check if a message mentions you
for _, msg in ipairs(messages) do
  if MessageParser.has_mention(msg, "Claude-abc12") then
    print("You were mentioned by", msg.from_claude_id)
  end
end
```

## Components

### Core Components

1. **Buffer Watcher** (`lua/vibing/core/buffer_watcher.lua`)
   - Uses `nvim_buf_attach` for real-time change detection
   - Supports multiple callbacks per buffer
   - Automatic cleanup on buffer deletion

2. **Message Parser** (`lua/vibing/application/shared_buffer/message_parser.lua`)
   - Parses message headers and extracts metadata
   - Detects mentions (`@Claude-{id}`, `@All`)
   - Validates message format

3. **Notification Dispatcher** (`lua/vibing/application/shared_buffer/notification_dispatcher.lua`)
   - Manages session registration
   - Dispatches notifications to mentioned sessions
   - Handles `@All` broadcasts

4. **Shared Buffer Manager** (`lua/vibing/application/shared_buffer/manager.lua`)
   - Creates and manages shared buffers
   - Integrates buffer watcher with message parser
   - Provides high-level API for posting messages

## Testing

### Manual Testing

1. **Create a shared buffer:**
   ```vim
   :VibingShared
   ```

2. **Run the demo to register mock sessions:**
   ```vim
   :VibingSharedDemo
   ```

3. **Manually add a message:**
   ```vim
   :lua require('vibing.application.shared_buffer.manager').append_message('abc12', 'Test message', {'Claude-def34'})
   ```

4. **Check for notifications:**
   ```vim
   :messages
   ```

### Automated Testing

Currently, only integration tests are available. Future work will include:

- Unit tests for MessageParser
- Unit tests for NotificationDispatcher
- Integration tests with real Claude sessions

## Limitations (PoC)

1. **No Integration with Chat Sessions**: Chat sessions don't automatically register with the shared buffer system yet
2. **Manual Message Posting**: No UI for easily posting messages from chat sessions
3. **Simple Notifications**: Currently only uses `vim.notify()` - no auto-response capabilities
4. **Single Shared Buffer**: Only one shared buffer is supported

## Next Steps

To evolve this PoC into a production feature:

1. **Phase 2: Chat Integration**
   - Automatically register chat sessions
   - Add UI for posting to shared buffer
   - Display notifications in chat buffer

2. **Phase 3: Enhanced Features**
   - Auto-response capabilities (AI decides whether to respond)
   - Multiple shared buffers (per-project, per-topic)
   - Rich notification system (highlights, sounds)

3. **Phase 4: Safety & Polish**
   - Infinite loop detection
   - Rate limiting
   - Comprehensive error handling
   - User documentation

## Known Issues

1. **No Infinite Loop Protection**: Claude sessions can get into response loops
2. **No Rate Limiting**: High-frequency messages can cause performance issues
3. **Limited Error Handling**: Some edge cases may not be handled gracefully

## Feedback

This is an experimental feature. Please report issues or suggestions:

1. **GitHub Issues**: [vibing.nvim issues](https://github.com/shabaraba/vibing.nvim/issues)
2. **Tag as**: `enhancement`, `experimental`, `buffer-change-detection`

## References

- [ADR 008: Buffer Change Detection for Multi-Agent Coordination](adr/008-buffer-change-detection-multi-agent.md)
- [ADR 002: Concurrent Execution Support](adr/002-concurrent-execution-support.md)
- Neovim `:help nvim_buf_attach()`
