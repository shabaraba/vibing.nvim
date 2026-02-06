# Features

## Message Timestamps

Chat messages include timestamps in their headers to help track conversation chronology and
facilitate searching through chat history.

**Timestamp Format:**

```markdown
## 2025-12-28 14:30:00 User

Message content here

## 2025-12-28 14:35:15 Assistant

Response content here
```

**Key Features:**

- **Automatic Timestamping**: Timestamps are automatically added when messages are sent (User) or responses are generated (Assistant)
- **Timezone**: All timestamps use the local system timezone (as returned by Lua's `os.date()`)
- **Backward Compatibility**: Legacy format without timestamps (`## User`, `## Assistant`) is fully supported
- **Searchability**: Timestamps enable easy searching by date/time:
  - Neovim search: `/2025-12-28` to find messages from a specific date
  - File search: `grep "## 2025-12-28" .vibing/chat/*.md` to search across chat files
  - Useful for extracting conversation history for daily reports

**Timestamp Recording:**

- User messages: Timestamp recorded when message is sent (`<CR>` pressed)
- Assistant responses: Timestamp recorded when response begins (in `on_done` callback)

**Implementation:**

The `lua/vibing/utils/timestamp.lua` module provides:

- `create_header(role, timestamp)` - Generate timestamped headers
- `extract_role(line)` - Parse role from both timestamped and legacy headers
- `has_timestamp(line)` - Check if header includes timestamp
- `extract_timestamp(line)` - Extract timestamp from header
- `is_header(line)` - Validate header format

## AskUserQuestion Support

vibing.nvim supports Claude's `AskUserQuestion` tool, allowing Claude to ask clarifying questions during code generation. Instead of guessing or assuming, Claude can present multiple-choice questions for user confirmation.

**How It Works:**

1. **Claude asks a question** - When Claude needs clarification, it sends an `AskUserQuestion` event
2. **Question appears in chat** - The question and options are inserted into the chat buffer as plain text:
   - **Single-select questions**: Numbered list format (`1. 2. 3.`)
   - **Multi-select questions**: Bullet list format (`- - -`)

```markdown
Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Please answer the question and press `<CR>` to send.
```

3. **User edits to select** - Delete unwanted options using Vim's standard editing commands (`dd`, etc.)
4. **Send with `<CR>`** - Press `<CR>` to send the answer back to Claude

**Example Workflow:**

```markdown
## Assistant

Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Which features do you need? (multiple selection allowed)

- Authentication
- Logging
- Caching

Please answer the question and press `<CR>` to send.
```

After editing (removing unwanted options):

```markdown
## Assistant

Which database should we use?

1. PostgreSQL

Which features do you need? (multiple selection allowed)

- Authentication
- Logging

Please answer the question and press `<CR>` to send.
```

**Key Features:**

- **Natural Vim workflow** - Use standard Vim commands (`dd`, `d{motion}`, etc.) to select options
- **Visual selection type indicators** - Numbered lists for single-select, bullet lists for multi-select
- **Single and multiple selection** - Delete unwanted options; remaining options are selected
- **Additional instructions** - Add custom notes below the options before sending
- **Non-invasive** - No special keymaps or UI overlays; works with any buffer editing

**Implementation Details:**

- Agent Wrapper sends `insert_choices` event and denies the tool
- Choices are inserted into chat buffer as plain markdown
  - Single-select (`multiSelect: false`): Numbered list format
  - Multi-select (`multiSelect: true`): Bullet list format
- User edits choices and sends via normal message flow (`<CR>`)
- Claude receives selection as a regular user message
- No special state management or Promise handling required
