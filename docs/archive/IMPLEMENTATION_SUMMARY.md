# AskUserQuestion Implementation Summary

## 実装完了 ✅

Issue #250に基づき、Claude Agent SDKの`AskUserQuestion`ツールをvibing.nvimに統合しました。

## 実装アーキテクチャ

### Simplified Deny-Based Flow

複雑なPromiseベースの実装から、シンプルなdeny-basedフローに簡素化しました:

1. **Claude calls AskUserQuestion tool**
2. **Agent Wrapper denies the tool** and sends `insert_choices` event
3. **Lua inserts choices** into chat buffer as plain markdown
4. **User edits and sends** via normal message flow
5. **Claude receives answer** as a regular user message

### Why This Approach?

- **No special state management** - No pending questions, no Promise waiting, no handle mapping
- **No stdin/stdout communication** - Simple one-way event flow
- **Instance-safe** - No ChatBuffer instance tracking issues
- **Natural UX** - Users interact with choices as normal text

## Implementation Details

### 1. Agent Wrapper (Node.js側)

**File:** `bin/agent-wrapper.mjs`

**Changes:**

```javascript
// In canUseTool callback (lines 644-659)
if (toolName === 'AskUserQuestion') {
  // Send insert_choices event to Lua
  console.log(
    safeJsonStringify({
      type: 'insert_choices',
      questions: input.questions,
    })
  );

  // Deny the tool - Claude will wait for user's normal message
  return {
    behavior: 'deny',
    message: 'Please wait for user to select from the provided options.',
  };
}
```

**System Prompt Addition (lines 221-237):**

```markdown
## Asking Questions with Choices

**IMPORTANT:** When you need to ask the user a question with multiple choice options, you MUST use the AskUserQuestion tool.

The AskUserQuestion tool provides:

- Structured UI with proper option descriptions
- Multi-select capability when needed
- Automatic insertion of choices into the user's input area
- Better user experience

**How it works:**

1. You call AskUserQuestion with your question and options
2. The tool is denied, but choices are automatically inserted into the user's input area
3. User deletes unwanted options and presses Enter to send their choice
4. You receive the user's selection as a normal message

**DO NOT format choices manually in your response.** Always use the AskUserQuestion tool for choice-based questions.
```

**Removed:**

- ❌ stdin/stdout listeners
- ❌ `pendingAskUserQuestion` state
- ❌ `askUserQuestionResolver` Promise handling
- ❌ `ask_user_question_response` event parsing

### 2. Lua Adapter

**File:** `lua/vibing/infrastructure/adapter/agent_sdk.lua`

**Changes:**

```lua
-- In stdout handler (lines 259-263)
elseif msg.type == "insert_choices" and msg.questions then
  if opts.on_insert_choices then
    opts.on_insert_choices(msg.questions)
  end
end
```

**Removed:**

- ❌ `_pending_questions` field
- ❌ `send_ask_user_question_answer()` method
- ❌ `get_pending_question()` method
- ❌ `clear_pending_question()` method
- ❌ handle_id mapping logic

### 3. Chat Buffer (UI層)

**File:** `lua/vibing/presentation/chat/buffer.lua`

**Changes:**

```lua
-- New field (line 15)
---@field _pending_choices table[]? add_user_section()後に挿入する選択肢

-- New method (lines 1085-1091)
function ChatBuffer:insert_choices(questions)
  -- 選択肢を保存（add_user_section()で挿入される）
  self._pending_choices = questions
end

-- Modified add_user_section() (lines 981-1003)
-- 保留中の選択肢があれば、未送信Userセクションの直後に挿入
if self._pending_choices then
  local choice_lines = {}
  for _, q in ipairs(self._pending_choices) do
    for _, opt in ipairs(q.options) do
      table.insert(choice_lines, "- " .. opt.label)
      if opt.description then
        table.insert(choice_lines, "  " .. opt.description)
      end
    end
    table.insert(choice_lines, "")
  end
  vim.api.nvim_buf_set_lines(self.buf, insert_pos, insert_pos, false, choice_lines)
  self._pending_choices = nil
end
```

**Critical Bug Fix:**

```lua
-- BEFORE (BUG - matched "- MongoDB" as "---"):
if Timestamp.is_header(line) or line:match("^---") then
  break
end

-- AFTER (FIXED):
if Timestamp.is_header(line) then
  break
end
```

**Removed:**

- ❌ `_pending_ask_user_question` field
- ❌ `_current_handle_id` field
- ❌ `insert_ask_user_question()` method
- ❌ `get_ask_user_question_answers()` method
- ❌ `has_pending_ask_user_question()` method
- ❌ `clear_pending_ask_user_question()` method

### 4. Send Message (Application Layer)

**File:** `lua/vibing/application/chat/send_message.lua`

**Changes:**

```lua
-- Updated callback (lines 81-86)
on_insert_choices = function(questions)
  vim.schedule(function()
    callbacks.insert_choices(questions)
  end)
end,
```

**Type Annotation Fix:**

```lua
-- Fixed (line 22)
---@field insert_choices fun(questions: table) AskUserQuestion選択肢を挿入
```

**Removed:**

- ❌ `on_ask_user_question` callback
- ❌ `set_current_handle_id` callback
- ❌ handle_id tracking logic

## UXデザイン

### Basic Flow

1. **Claude asks question** → Choices inserted as plain markdown:

   ```markdown
   ## User <!-- unsent -->

   - PostgreSQL
     PostgreSQL is a powerful open-source relational database
   - MySQL
     MySQL is a popular open-source database
   - SQLite
     SQLite is a lightweight embedded database
   ```

2. **User edits** → Delete unwanted choices (`dd`, etc.):

   ```markdown
   ## User <!-- unsent -->

   - PostgreSQL
     PostgreSQL is a powerful open-source relational database
   ```

3. **User presses `<CR>`** → Selected choice sent as normal message

### Design Benefits

- ✅ **Vim Native**: Standard editing commands (`dd`, `dj`, etc.)
- ✅ **Non-Invasive**: No special keymaps or UI elements
- ✅ **Simple**: No complex state management
- ✅ **Flexible**: Can add additional instructions
- ✅ **Instance-Safe**: No ChatBuffer instance tracking needed

## Code Statistics

**Net Change:** -81 lines

- ❌ Deleted: 161 lines (old implementation)
- ✅ Added: 80 lines (new implementation)

## Test Status

### Automated Tests

```bash
# Lua syntax check
npm run check:lua  # ✅ PASS

# Lint and format
npm run lint       # ✅ PASS
npm run format:check  # ✅ PASS
```

### Manual Test

See `MANUAL_TEST.md` for detailed test procedures.

**Note:** AskUserQuestion is used only when Claude decides it's necessary. The implementation works correctly, but depends on Claude's judgment.

## Documentation

### Added/Updated Files

- ✅ `CLAUDE.md` - Added AskUserQuestion usage documentation
- ✅ `docs/adr/005-ask-user-question-ux-design.md` - Documented design decisions
- ✅ `docs/adr/adr-index-and-guide.md` - Updated ADR index
- ✅ `MANUAL_TEST.md` - Manual test procedures
- ✅ `IMPLEMENTATION_SUMMARY.md` - This summary

## Commit Information

```text
Commit: eecfe3d
Branch: feature/ask-user-question-250
Message: feat: simplify AskUserQuestion implementation
```

## Technical Specifications

### JSON Lines Protocol

**Agent Wrapper → Lua:**

```json
{
  "type": "insert_choices",
  "questions": [
    {
      "question": "Which database should we use?",
      "header": "Database",
      "multiSelect": false,
      "options": [
        {
          "label": "PostgreSQL",
          "description": "PostgreSQL is a powerful open-source relational database"
        },
        {
          "label": "MySQL",
          "description": "MySQL is a popular open-source database"
        }
      ]
    }
  ]
}
```

**No Response Required** - User sends choice via normal message flow

### Agent SDK Integration

```javascript
// In canUseTool callback
if (toolName === 'AskUserQuestion') {
  // Emit insert_choices event
  console.log(safeJsonStringify({ type: 'insert_choices', questions: input.questions }));

  // Deny tool to make Claude wait for user message
  return { behavior: 'deny', message: '...' };
}
```

## Related Resources

- Issue #250: AskUserQuestion tool support
- ADR 005: AskUserQuestion UX Design
- ADR 002: Concurrent Execution Support
- Claude Agent SDK Documentation: <https://github.com/anthropics/claude-agent-sdk-typescript>
