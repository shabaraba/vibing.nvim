# Call Hierarchy - vibing.nvim

This document provides comprehensive call hierarchy diagrams showing how code flows through vibing.nvim's Clean Architecture layers.

**Last Updated**: 2025-12-30
**Architecture Version**: Post-2025 Refactoring (Clean Architecture)

## Table of Contents

- [Overview](#overview)
- [Layer Dependencies](#layer-dependencies)
- [Entry Point](#entry-point)
- [Command Flows](#command-flows)
  - [Chat Commands](#chat-commands)
  - [Context Commands](#context-commands)
  - [Inline Commands](#inline-commands)
- [Message Sending Flow](#message-sending-flow)
- [Major Call Paths Summary](#major-call-paths-summary)
- [Before/After Comparison](#beforeafter-comparison)

## Overview

vibing.nvim follows Clean Architecture principles with clear layer separation:

```
Entry Point (init.lua)
    ↓
Presentation Layer (Controllers + Views)
    ↓
Application Layer (Use Cases)
    ↓
Domain Layer (Domain Models)
    ↓
Infrastructure Layer (Adapters, RPC, Storage)
```

**Key Principle**: Dependencies point inward (from outer to inner layers).

## Layer Dependencies

```
┌─────────────────────────────────────────────────────────────────┐
│ Entry Point (init.lua)                                          │
│   - Command registration                                         │
│   - Plugin initialization                                        │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Presentation Layer                                               │
│   Controllers (Input):          Views (Output):                 │
│   - chat/controller.lua         - chat/view.lua                 │
│   - inline/controller.lua       - chat/buffer.lua               │
│   - context/controller.lua      - ui/inline_picker.lua          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Application Layer (Use Cases)                                    │
│   - chat/use_case.lua                                           │
│   - inline/use_case.lua                                         │
│   - context/manager.lua                                         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Domain Layer (Business Logic)                                    │
│   - domain/chat/session.lua                                     │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│ Infrastructure Layer (External Services)                         │
│   - adapters/agent_sdk.lua                                      │
│   - infrastructure/storage/frontmatter.lua                      │
│   - infrastructure/rpc/                                         │
└─────────────────────────────────────────────────────────────────┘
```

**Dependency Rules**:

- ✅ Outer layers can depend on inner layers
- ❌ Inner layers MUST NOT depend on outer layers
- ✅ Use Cases return Domain Models, not Views
- ✅ Controllers orchestrate Use Cases and Views

## Entry Point

### `init.lua::setup()`

All Neovim commands are registered here and delegate to Presentation Controllers:

```
init.lua
├─ M.setup(opts)
│   ├─ Config.setup(opts)
│   ├─ require("vibing.infrastructure.rpc.server").setup()  [if MCP enabled]
│   ├─ vim.api.nvim_create_user_command("VibingChat", ...)
│   ├─ vim.api.nvim_create_user_command("VibingToggleChat", ...)
│   ├─ vim.api.nvim_create_user_command("VibingSlashCommands", ...)
│   ├─ vim.api.nvim_create_user_command("VibingSetFileTitle", ...)
│   ├─ vim.api.nvim_create_user_command("VibingContext", ...)
│   ├─ vim.api.nvim_create_user_command("VibingClearContext", ...)
│   ├─ vim.api.nvim_create_user_command("VibingInline", ...)
│   └─ vim.api.nvim_create_user_command("VibingCancel", ...)
```

## Command Flows

### Chat Commands

#### `:VibingChat [file]`

**Purpose**: Create new chat or open existing chat file

```
:VibingChat args → init.lua (L165-170)
    ↓
presentation/chat/controller.lua::handle_open(args)
    ↓
    ├─ [if args == ""] → application/chat/use_case.lua::create_new()
    │       ↓
    │       ├─ domain/chat/session.lua::new()
    │       ├─ infrastructure/storage/frontmatter.lua (session metadata)
    │       └─ return ChatSession
    │
    └─ [if args != ""] → application/chat/use_case.lua::open_file(args)
            ↓
            ├─ domain/chat/session.lua::load_from_file(file_path)
            ├─ infrastructure/storage/frontmatter.lua::parse()
            └─ return ChatSession
    ↓
presentation/chat/view.lua::render(session)
    ↓
    ├─ presentation/chat/buffer.lua::new()
    ├─ ChatBuffer:open()
    └─ vim.api.nvim_buf_set_lines() [display session content]
```

#### `:VibingToggleChat`

**Purpose**: Toggle chat window visibility

```
:VibingToggleChat → init.lua (L172-174)
    ↓
presentation/chat/controller.lua::handle_toggle()
    ↓
    ├─ presentation/chat/view.lua::is_open()
    │   ├─ [if true] → view.close()
    │   └─ [if false] ↓
    │
    └─ application/chat/use_case.lua::get_or_create_session()
            ↓
            ├─ [if M._current_session exists] → return M._current_session
            └─ [else] → create_new() → return new ChatSession
    ↓
presentation/chat/view.lua::render(session)
    └─ (same as VibingChat flow)
```

#### `:VibingSlashCommands`

**Purpose**: Show slash command picker in chat

```
:VibingSlashCommands → init.lua (L176-178)
    ↓
presentation/chat/controller.lua::show_slash_commands()
    ↓
ui/command_picker.lua::show()
    └─ vim.ui.select() [display picker UI]
```

#### `:VibingSetFileTitle`

**Purpose**: Generate AI title for current chat file

```
:VibingSetFileTitle → init.lua (L180-182)
    ↓
presentation/chat/controller.lua::handle_set_file_title()
    ↓
    ├─ presentation/chat/view.lua::is_current_buffer_chat()
    │   └─ [if false] → notify.warn() and return
    │
    ├─ presentation/chat/view.lua::get_current()
    │   └─ return ChatBuffer instance
    │
    └─ application/chat/handlers/set_file_title.lua::execute()
            ↓
            ├─ adapters/agent_sdk.lua::execute() [generate title]
            ├─ vim.fn.rename() [rename file]
            └─ domain/chat/session.lua::set_file_path()
```

### Context Commands

#### `:VibingContext [path]`

**Purpose**: Add file or selection to context

```
:VibingContext opts → init.lua (L184-192)
    ↓
presentation/context/controller.lua::handle_add(opts)
    ↓
    ├─ [if opts.range > 0] → application/context/manager.lua::add_selection()
    │       ↓
    │       ├─ Get visual selection range
    │       ├─ Format as @file:path:L10-L25
    │       └─ Add to context list
    │
    ├─ [if opts.args != ""] → application/context/manager.lua::add(path)
    │       ↓
    │       ├─ Resolve file path
    │       ├─ Format as @file:path
    │       └─ Add to context list
    │
    ├─ [if oil.nvim buffer] → integrations/oil.lua::send_to_chat()
    │       └─ Get oil.nvim entry and add to context
    │
    └─ [else] → application/context/manager.lua::add() [current buffer]
    ↓
presentation/context/controller.lua::_update_chat_context_if_open()
    ↓
    └─ presentation/chat/view.lua::get_current():_update_context_line()
```

#### `:VibingClearContext`

**Purpose**: Clear all context

```
:VibingClearContext → init.lua (L194-196)
    ↓
presentation/context/controller.lua::handle_clear()
    ↓
    ├─ application/context/manager.lua::clear()
    │   └─ M._context_files = {}
    │
    └─ _update_chat_context_if_open()
            └─ presentation/chat/view.lua::get_current():_update_context_line()
```

### Inline Commands

#### `:VibingInline [action|prompt]`

**Purpose**: Quick inline code actions with rich UI picker

```
:'<,'>VibingInline args → init.lua (L198-210)
    ↓
presentation/inline/controller.lua::handle_execute(args)
    ↓
    ├─ [if args == ""] → ui/inline_picker.lua::show()
    │       ↓
    │       ├─ Display split-panel UI (actions + input)
    │       ├─ User selects action + optional instruction
    │       └─ callback(action, instruction)
    │               ↓
    │               └─ application/inline/use_case.lua::execute(action_arg)
    │
    └─ [if args != ""] → application/inline/use_case.lua::execute(args)
            ↓
            ├─ actions/inline.lua::handle_action()
            │   ↓
            │   ├─ Get visual selection or current buffer
            │   ├─ Format prompt with action + code
            │   ├─ adapters/agent_sdk.lua::stream()
            │   │   ↓
            │   │   ├─ bin/agent-wrapper.mjs [Node.js subprocess]
            │   │   ├─ Claude Agent SDK execution
            │   │   └─ Stream JSON Lines responses
            │   │
            │   └─ ui/output_buffer.lua::show() [display results]
            │
            └─ actions/inline.lua::_process_queue() [handle concurrent requests]
```

## Message Sending Flow

### User sends message in chat buffer

**Trigger**: Press `<CR>` in chat buffer

```
ChatBuffer keymap <CR> → presentation/chat/buffer.lua::_send_message()
    ↓
    ├─ Parse message content
    ├─ Extract frontmatter metadata (mode, model, permissions)
    ├─ Collect context files
    │   └─ application/context/manager.lua::get_context_files()
    │
    └─ actions/chat.lua::send_message_stream()
            ↓
            ├─ Format system prompt with context
            ├─ adapters/agent_sdk.lua::stream()
            │   ↓
            │   ├─ bin/agent-wrapper.mjs --prompt "..." --session-id "..."
            │   ├─ Claude Agent SDK::stream()
            │   └─ Read JSON Lines from stdout
            │       ├─ {"type": "chunk", "text": "..."}
            │       ├─ {"type": "tool_use", "tool": "Edit", ...}
            │       ├─ {"type": "session", "session_id": "..."}
            │       └─ {"type": "done"}
            │
            ├─ on_chunk: Append to buffer in real-time
            ├─ on_tool_use: Record file modifications
            └─ on_done: Update session ID, save file
                    ↓
                    ├─ domain/chat/session.lua::update_session_id()
                    ├─ infrastructure/storage/frontmatter.lua::serialize()
                    └─ vim.fn.writefile() [persist to disk]
```

## Major Call Paths Summary

### 1. Chat Creation Flow

```
init.lua → chat/controller → chat/use_case → ChatSession → chat/view → ChatBuffer
```

### 2. Message Streaming Flow

```
ChatBuffer → actions/chat → agent_sdk adapter → Node.js wrapper → Claude SDK → JSON Lines
```

### 3. Context Management Flow

```
init.lua → context/controller → context/manager → chat/view → ChatBuffer
```

### 4. Inline Action Flow

```
init.lua → inline/controller → inline_picker → inline/use_case → actions/inline → agent_sdk
```

### 5. File Operations (Tool Use)

```
Agent SDK → JSON Lines → actions/chat::on_tool_use → infrastructure/file_operations
```

## Before/After Comparison

### Before Refactoring (Anti-Pattern)

```
init.lua::VibingChat
    ↓
application/chat/use_case.lua::open()  ❌ Directly creates UI
    ↓
presentation/chat/buffer.lua::new()    ❌ Application depends on Presentation
    └─ ChatBuffer:open()
```

**Problems**:

- Application layer depends on Presentation layer (wrong direction)
- No domain model (business logic mixed with UI)
- Commands directly call Use Cases (skipping Controller)

### After Refactoring (Clean Architecture)

```
init.lua::VibingChat
    ↓
presentation/chat/controller.lua::handle_open()  ✅ Controller handles input
    ↓
application/chat/use_case.lua::create_new()      ✅ Returns domain model
    ↓
domain/chat/session.lua::new()                   ✅ Pure business entity
    ↓
presentation/chat/view.lua::render(session)      ✅ View handles output
    └─ ChatBuffer:open()
```

**Benefits**:

- ✅ Proper dependency direction (outer → inner)
- ✅ Controller pattern (input handling)
- ✅ View pattern (output rendering)
- ✅ Domain model (business logic isolated from UI)
- ✅ Testable (each layer can be tested independently)
- ✅ Flexible (can change UI without touching business logic)

## Related Documentation

- [Architecture Refactoring 2025](./refactoring-2025.md) - Details of the Clean Architecture refactoring
- [CLAUDE.md](../../CLAUDE.md) - Project overview and architecture principles
- [ADR 002: Concurrent Execution Support](../adr/002-concurrent-execution-support.md) - Multi-session architecture

---

**Generated**: 2025-12-30
**Maintainer**: @shabaraba (vibing.nvim development team)
