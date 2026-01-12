# Buffer Change Detection PoC

**Status:** Phase 3 (State Persistence Complete)

This document describes the Proof of Concept (PoC) implementation for buffer change detection and multi-agent coordination in vibing.nvim.

## Overview

This feature enables multiple Claude sessions to communicate and coordinate through a shared buffer. Each session can:

- Post messages to a shared buffer
- Mention other Claude sessions using `@Claude-{id}`
- Broadcast to all sessions using `@All`
- Receive real-time notifications when mentioned
- **Phase 2**: Enable/disable shared buffer integration per chat session
- **Phase 2**: Use slash commands for easy interaction
- **Phase 2.5**: Real-time mention interruption via canToolUse integration
- **Phase 3**: State persistence - shared buffer settings auto-restore when reopening chats

## Architecture

See [ADR 008: Buffer Change Detection for Multi-Agent Coordination](adr/008-buffer-change-detection-multi-agent.md) for detailed architecture.

## What's New in Phase 2

**ChatBuffer Integration**: Chat sessions now have built-in support for shared buffer communication. No more manual registration - just use slash commands!

**New Slash Commands**:
- `/enable-shared` - Enable shared buffer integration for this chat
- `/disable-shared` - Disable shared buffer integration
- `/shared [position]` - Open shared buffer window
- `/post <message> [@mentions]` - Post to shared buffer with mentions

**Automatic Registration**: When you enable shared buffer in a chat, it automatically registers with a unique Claude ID based on the session ID.

## Quick Start

### 1. Basic Demo (No ChatBuffer)

The easiest way to see the core feature:

```vim
:VibingSharedDemo
```

This will:
- Create a shared buffer
- Register 3 mock Claude sessions (Claude-abc12, Claude-def34, Claude-xyz56)
- Post sample messages with mentions
- Display notifications received by each session

### 2. ChatBuffer Integration (Phase 2)

**Step-by-step guide to use shared buffer with real chat sessions**:

1. **Open two chat windows**:
   ```vim
   :VibingChat right
   :VibingChat left
   ```

2. **Initialize both sessions** (send a message to each):
   ```
   Hello
   ```

3. **Enable shared buffer in both chats**:
   ```
   /enable-shared
   ```
   Note the Claude ID displayed (e.g., "You are Claude-abc12")

4. **From the first chat, post a message**:
   ```
   /post Need help with testing @Claude-def34
   ```
   (Replace `def34` with the actual ID from step 3)

5. **Check the second chat** - you should see a notification!

6. **Open the shared buffer to see all messages**:
   ```
   /shared float
   ```

### 3. State Persistence (Phase 3)

**Status:** Complete

Phase 3 adds automatic state persistence so your shared buffer configuration is preserved across sessions.

**How it works:**

1. **Enable shared buffer** in a chat:
   ```
   /enable-shared
   ```
   This automatically saves `shared_buffer_enabled: true` to the chat frontmatter.

2. **Save the chat** (`:w` or automatic save)

3. **Reopen the chat later** (`:e chat-file.vibing` or `:VibingChat path/to/chat.vibing`)

4. **Automatic reconnection** - The chat automatically:
   - Reads `shared_buffer_enabled: true` from frontmatter
   - Re-enables shared buffer integration
   - Registers with the same Claude ID (based on session_id)
   - Reconnects to the notification system

**Benefits:**
- No need to run `/enable-shared` every time you reopen a chat
- Your multi-agent collaboration setup is preserved
- Claude ID consistency within the same session

**Example Frontmatter:**

```yaml
---
vibing.nvim: true
session_id: abc12345
created_at: 2026-01-12T10:00:00
mode: code
model: sonnet
shared_buffer_enabled: true
---
```

### 4. View Registered Sessions

```vim
:VibingListSessions
```

### 5. Open the Shared Buffer

```vim
:VibingShared           " Open in right split (default)
:VibingShared current   " Open in current window
:VibingShared left      " Open in left split
:VibingShared float     " Open in floating window
```

Or from within a chat:
```
/shared
/shared float
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

5. **ChatBuffer Integration** (Phase 2) (`lua/vibing/presentation/chat/buffer.lua`)
   - Claude ID generation from session ID
   - Automatic registration with shared buffer system
   - Notification handler for incoming mentions
   - Methods: `enable_shared_buffer()`, `disable_shared_buffer()`, `post_to_shared_buffer()`

6. **Slash Command Handlers** (Phase 2)
   - `/enable-shared` (`lua/vibing/application/chat/handlers/enable_shared.lua`)
   - `/disable-shared` (`lua/vibing/application/chat/handlers/disable_shared.lua`)
   - `/shared` (`lua/vibing/application/chat/handlers/shared.lua`)
   - `/post` (`lua/vibing/application/chat/handlers/post.lua`)

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

## Limitations (Phase 2)

1. **~~No Integration with Chat Sessions~~** ✅ **DONE (Phase 2)**: Chat sessions now support shared buffer via `/enable-shared`
2. **~~Manual Message Posting~~** ✅ **DONE (Phase 2)**: Use `/post` slash command
3. **~~Display notifications in chat buffer~~** ✅ **DONE (Phase 2)**: Notifications via `vim.notify()`
4. **No State Persistence**: `_shared_buffer_enabled` state is not saved to frontmatter (sessions must re-enable after reload)
5. **Simple Notifications**: Currently only uses `vim.notify()` - no auto-response capabilities
6. **Single Shared Buffer**: Only one shared buffer is supported
7. **Manual Claude ID Lookup**: Must manually note other sessions' Claude IDs for mentions

## Next Steps

**Phase 2 Complete!** ✅ Chat integration and slash commands are now available.

To evolve this into a production feature:

1. **~~Phase 2: Chat Integration~~** ✅ **COMPLETED**
   - ✅ Automatically register chat sessions via `/enable-shared`
   - ✅ Add slash commands for posting to shared buffer
   - ✅ Display notifications

2. **Phase 3: Enhanced Features** (Planned)
   - Auto-response capabilities (AI decides whether to respond)
   - State persistence (save `shared_buffer_enabled` to frontmatter)
   - Multiple shared buffers (per-project, per-topic)
   - Rich notification system (in-buffer indicators, highlights)
   - Claude ID auto-completion for mentions

3. **Phase 4: Safety & Polish** (Planned)
   - Infinite loop detection
   - Rate limiting
   - Comprehensive error handling
   - Production-ready documentation
   - Performance optimization

## Known Issues

1. **No Infinite Loop Protection**: Claude sessions can get into response loops
2. **No Rate Limiting**: High-frequency messages can cause performance issues
3. **Limited Error Handling**: Some edge cases may not be handled gracefully
4. **No State Persistence**: Shared buffer integration must be manually re-enabled after chat reload

## Feedback

This is an experimental feature. Please report issues or suggestions:

1. **GitHub Issues**: [vibing.nvim issues](https://github.com/shabaraba/vibing.nvim/issues)
2. **Tag as**: `enhancement`, `experimental`, `buffer-change-detection`

## References

- [ADR 008: Buffer Change Detection for Multi-Agent Coordination](adr/008-buffer-change-detection-multi-agent.md)
- [ADR 002: Concurrent Execution Support](adr/002-concurrent-execution-support.md)
- Neovim `:help nvim_buf_attach()`
