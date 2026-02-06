# Self-Testing Procedures for vibing.nvim

This document provides procedures for Claude to automatically test vibing.nvim after implementing new features.

## Overview

vibing.nvim can test itself using a separate Neovim instance. This enables automatic QA and self-correction after feature implementation, reducing user burden and improving code quality.

**Key Capabilities:**

- E2E testing via separate Neovim instances controlled via RPC
- Automatic message sending and response verification
- 3-try auto-fix rule for error handling
- Integration with plenary.nvim test framework

## Architecture

```text
Test Runner (Current Nvim)
  ├─ lua/vibing/testing/e2e_helper.lua
  │   ├─ spawn_nvim_instance()  - Launch child Nvim via jobstart(rpc=true)
  │   ├─ send_keys()             - Send key input via rpcrequest
  │   ├─ wait_for_buffer_content() - Poll buffer until pattern matches
  │   └─ cleanup_instance()      - Stop job
  │
  └─ tests/e2e/*.spec.lua - plenary.nvim test specs
       └─ Test Neovim Instance (Child Process)
            └─ vibing.nvim running with test configuration
```

**Communication**: Parent Nvim ←RPC→ Child Nvim (jobstart with `rpc=true`)

## Running Tests

```bash
# Run all E2E tests
npm run test:e2e

# Run specific test file
nvim --headless -c "PlenaryBustedDirectory tests/e2e/ { minimal_init = 'tests/minimal_init.lua' }"

# Run all tests (unit + E2E)
npm test
```

## Test Execution Flow

### 1. Spawn Separate Neovim Instance

```lua
local helper = require("vibing.testing.e2e_helper")

local instance = helper.spawn_nvim_instance({
  headless = true,                    -- Run without UI
  init_script = "tests/minimal_init.lua",  -- Load vibing.nvim
  cwd = vim.fn.getcwd(),              -- Working directory
})
```

**What Happens:**

- Child Neovim process starts via `vim.fn.jobstart()`
- vibing.nvim loads with test configuration
- RPC channel established for remote control
- Child instance gets unique RPC port (9876-9925)

### 2. Execute Commands and Send Input

```lua
-- Execute Neovim command
helper.send_keys(instance, ":VibingChat<CR>")

-- Navigate and input text
helper.send_keys(instance, "G")           -- Go to end
helper.send_keys(instance, "i")           -- Insert mode
helper.send_keys(instance, 'Say "test"')  -- Type message
helper.send_keys(instance, "<Esc>")       -- Exit insert mode
helper.send_keys(instance, "<CR>")        -- Send message
```

### 3. Verify Results

```lua
-- Wait for pattern to appear in buffer (max 30 seconds)
local ok = helper.wait_for_buffer_content(
  instance,
  "## .* Assistant",  -- Regex pattern
  30000               -- Timeout in milliseconds
)

assert.is_true(ok, "Assistant response should appear within 30 seconds")
```

### 4. Cleanup

```lua
helper.cleanup_instance(instance)  -- Stops child Nvim process
```

## Writing Test Cases

Test files should be placed in `tests/e2e/` with `_spec.lua` suffix.

**Example: `tests/e2e/chat_basic_flow_spec.lua`**

```lua
local helper = require("vibing.testing.e2e_helper")

describe("E2E: Chat basic flow", function()
  local nvim_instance

  before_each(function()
    -- Spawn fresh instance for each test
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    -- Always cleanup
    helper.cleanup_instance(nvim_instance)
  end)

  it("should create chat buffer and display initial state", function()
    -- Execute command
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(2000)

    -- Verify buffer creation
    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", 5000)
    assert.is_true(ok, "Chat buffer should be created with .md extension")

    -- Verify frontmatter
    ok = helper.wait_for_buffer_content(nvim_instance, "created_at:", 2000)
    assert.is_true(ok, "Frontmatter should contain created_at field")
  end)
end)
```

**Best Practices:**

- Use `before_each` to spawn fresh instance for isolation
- Use `after_each` for cleanup (prevents zombie processes)
- Use descriptive assertion messages for debugging
- Set appropriate timeouts (chat responses: 30s, buffer changes: 2-5s)
- Use regex patterns for flexible matching (e.g., `"## .* Assistant"`)

## 3-Try Auto-Fix Rule

When a test fails after implementing a new feature, follow this procedure:

### Step 1: Run Tests

```bash
npm run test:e2e
```

### Step 2: Analyze Failure

If test fails:

1. **Read error output** - Identify which assertion failed and why
2. **Check test case** - Is the test correct or does it need updating?
3. **Check implementation** - Does the feature work as expected?
4. **Identify root cause** - Implementation bug vs test bug vs timing issue

### Step 3: Fix and Retry (Attempt 1)

1. Make targeted fix to either implementation or test
2. Re-run tests: `npm run test:e2e`
3. If passed → Success, proceed to Phase 6 (Code Review)
4. If failed → Continue to Attempt 2

### Step 4: Fix and Retry (Attempt 2)

1. Re-analyze error output (may be different from Attempt 1)
2. Make additional fix
3. Re-run tests: `npm run test:e2e`
4. If passed → Success, proceed to Phase 6
5. If failed → Continue to Attempt 3

### Step 5: Fix and Retry (Attempt 3)

1. Re-analyze error output (final attempt)
2. Make final fix
3. Re-run tests: `npm run test:e2e`
4. If passed → Success, proceed to Phase 6
5. If failed → **Escalate to user**

### Step 6: Escalation

After 3 failed attempts, report to user:

```markdown
テストが3回の修正試行後も失敗しています。以下の情報を報告します:

**エラー内容:**
[最後のエラーメッセージをコピー]

**試行した修正:**

1. [Attempt 1で試した修正内容]
2. [Attempt 2で試した修正内容]
3. [Attempt 3で試した修正内容]

**推測される原因:**
[何が問題だと考えているか]

**次のステップの提案:**
[どうすれば解決できそうか]
```

**Important Notes:**

- Do NOT give up before 3 attempts
- Each attempt should be a DIFFERENT fix based on new analysis
- Always re-run tests after each fix (don't assume it worked)
- If test passes on any attempt, immediately stop and proceed to next phase

## Test Scenarios to Cover

When implementing new features, add E2E tests for:

### Chat Features

- ✅ Chat buffer creation and initial state
- ✅ Message send and Assistant response
- [ ] Message editing and re-sending
- [ ] Context file addition via `/context`
- [ ] Slash command execution (`/mode`, `/model`, `/save`, etc.)
- [ ] Chat forking (`:VibingChatFork`)
- [ ] Multi-turn conversations

### Worktree Features

- [ ] `:VibingChatWorktree` creates worktree and chat
- [ ] Configuration files copied to worktree
- [ ] `node_modules` symlinked correctly
- [ ] Chat files saved in `.vibing/worktrees/<branch>/`

### Inline Actions

- [ ] `:VibingInline fix` modifies code
- [ ] `:VibingInline explain` shows output
- [ ] Inline action queue (multiple concurrent requests)

### MCP Tools

- [ ] `nvim_list_instances` returns correct ports
- [ ] `nvim_chat_send_message` sends to correct chat
- [ ] LSP tools work in background buffers

### Permission System

- [ ] Tool approval UI appears correctly
- [ ] Session-level permissions persist
- [ ] Granular rules are enforced

## Integration with Feature Development Workflow

When implementing a new feature, follow this sequence:

1. **Phase 1-4**: Requirements → Exploration → Clarification → Architecture
2. **Phase 5**: Implementation
   - Write feature code
   - Update documentation
   - Add npm scripts if needed
3. **Phase 5.4: Test Case Design** (NEW - AUTOMATED)
   - Call `/test-design` skill to generate test scenarios
   - Review generated test cases
   - Implement Critical and High priority tests
   - Save test file in `tests/e2e/`
4. **Phase 5.5: Self-Testing** (NEW)
   - Run `npm run test:e2e`
   - Apply 3-try auto-fix rule if failures occur
   - Escalate to user if still failing after 3 attempts
5. **Phase 6**: Code Review (only proceed if tests pass)
6. **Phase 7**: Final summary

**Critical Rule**: Do NOT proceed to Phase 6 (Code Review) if E2E tests are failing. Either fix the tests via 3-try rule or escalate to user.

### Phase 5.4: Test Case Design - Detailed Procedure

After completing feature implementation, use the Test Design skill to automatically generate test scenarios:

#### Step 1: Invoke the Skill

```
/test-design

I implemented [feature description].

Changed files:
- [list of new/modified files]

Existing tests:
- [list of existing test files]
```

**Example:**

```
/test-design

I implemented a new slash command `/export` that exports chat history to Markdown files.

Changed files:
- lua/vibing/application/chat/slash_commands.lua (added export_command)
- lua/vibing/utils/markdown_exporter.lua (new file)

Existing tests:
- tests/e2e/chat_basic_flow_spec.lua (basic chat operations)
```

#### Step 2: Review Generated Scenarios

The skill will output:

1. **Test Scenario Analysis** - Categorized test scenarios
2. **Priority Ranking** - Tests ranked by importance
3. **Test Code Templates** - Ready-to-implement code

Review the scenarios and verify they cover:

- ✅ Happy path (most common use case)
- ✅ Error cases (validation, network, permissions)
- ✅ Edge cases (boundary values, special chars)
- ✅ Integration points (interaction with other features)

#### Step 3: Implement Tests

Focus on implementing tests in priority order:

1. **Critical tests** (必須) - Core functionality
2. **High priority tests** (重要) - Error handling
3. **Medium priority tests** (推奨) - Edge cases (if time allows)
4. **Low priority tests** (任意) - Optimization (future work)

Save test file as `tests/e2e/[feature-name]_spec.lua`

#### Step 4: Run Tests

```bash
npm run test:e2e
```

If tests fail, proceed to Phase 5.5 (3-try auto-fix rule).

### Test Design Skill Reference

For detailed documentation on the Test Design skill, see:

- `.claude/skills/test-design/SKILL.md` - Complete skill documentation

**Quick Tips:**

- Be specific in feature description
- List all changed files (use `git diff --name-only`)
- Review generated tests - don't blindly accept
- Implement Critical/High tests first

## Helper Function Reference

### `spawn_nvim_instance(config)`

Spawn a separate Neovim instance for testing.

**Parameters:**

- `config.headless` (boolean) - Run without UI
- `config.init_script` (string) - Path to init script (e.g., `"tests/minimal_init.lua"`)
- `config.cwd` (string, optional) - Working directory

**Returns:**

- `instance` table with `job_id` field

**Example:**

```lua
local instance = helper.spawn_nvim_instance({
  headless = true,
  init_script = "tests/minimal_init.lua",
})
```

### `send_keys(instance, keys)`

Send key input to the Neovim instance.

**Parameters:**

- `instance` - Instance from `spawn_nvim_instance()`
- `keys` (string) - Key sequence (e.g., `":VibingChat<CR>"`, `"G"`, `"iHello<Esc>"`)

**Example:**

```lua
helper.send_keys(instance, ":VibingChat<CR>")
helper.send_keys(instance, "G")  -- Go to end
helper.send_keys(instance, "i")  -- Insert mode
helper.send_keys(instance, "Hello")  -- Type text
helper.send_keys(instance, "<Esc>")  -- Exit insert mode
```

### `wait_for_buffer_content(instance, pattern, timeout)`

Poll buffer content until pattern matches (or timeout).

**Parameters:**

- `instance` - Instance from `spawn_nvim_instance()`
- `pattern` (string) - Lua pattern or regex (e.g., `"%.md"`, `"## .* Assistant"`)
- `timeout` (number) - Timeout in milliseconds

**Returns:**

- `true` if pattern matched within timeout
- `false` if timeout reached

**Example:**

```lua
local ok = helper.wait_for_buffer_content(instance, "## .* Assistant", 30000)
assert.is_true(ok, "Assistant response should appear")
```

**Recommended Timeouts:**

- Buffer creation: 2000-5000ms
- Frontmatter updates: 1000-2000ms
- Assistant responses: 30000ms (30 seconds)
- Command execution: 1000-2000ms

### `cleanup_instance(instance)`

Stop the Neovim instance job.

**Parameters:**

- `instance` - Instance from `spawn_nvim_instance()`

**Example:**

```lua
helper.cleanup_instance(instance)
```

**Important:** Always call this in `after_each()` to prevent zombie processes.

## Troubleshooting

### Test hangs forever

**Cause:** Pattern never matches in `wait_for_buffer_content()`

**Fix:**

1. Check pattern is correct (use Lua pattern syntax, not plain string)
2. Increase timeout if operation is legitimately slow
3. Add debug output: `print(vim.inspect(lines))` before pattern check

### "Job not found" error

**Cause:** Instance already cleaned up or failed to start

**Fix:**

1. Check `instance.job_id` is valid before calling RPC functions
2. Verify init script path is correct
3. Check for errors in `on_exit` callback

### Tests pass individually but fail when run together

**Cause:** State pollution between tests

**Fix:**

1. Ensure `after_each()` cleans up ALL resources
2. Use fresh `spawn_nvim_instance()` in `before_each()`
3. Don't rely on global state

### Child Neovim crashes

**Cause:** Invalid RPC request or timeout

**Fix:**

1. Check RPC function name is correct (e.g., `"nvim_get_current_buf"` not `"get_current_buf"`)
2. Verify arguments match Neovim API signature
3. Add error handling around RPC calls

## Example: Testing a New Feature

**Scenario:** You just implemented a new slash command `/export` that exports chat to Markdown.

**Test to Write:**

```lua
it("should export chat to markdown file via /export", function()
  -- Setup: Create chat and send message
  helper.send_keys(nvim_instance, ":VibingChat<CR>")
  vim.wait(2000)

  helper.send_keys(nvim_instance, "G")
  helper.send_keys(nvim_instance, "i")
  helper.send_keys(nvim_instance, "Test message")
  helper.send_keys(nvim_instance, "<Esc>")
  helper.send_keys(nvim_instance, "<CR>")

  -- Wait for response
  local ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", 30000)
  assert.is_true(ok, "Assistant should respond")

  -- Execute /export command
  helper.send_keys(nvim_instance, "G")
  helper.send_keys(nvim_instance, "i")
  helper.send_keys(nvim_instance, "/export output.md")
  helper.send_keys(nvim_instance, "<Esc>")
  helper.send_keys(nvim_instance, "<CR>")

  -- Wait for export confirmation
  ok = helper.wait_for_buffer_content(nvim_instance, "Exported to output.md", 5000)
  assert.is_true(ok, "Export confirmation should appear")

  -- Verify file was created (via RPC)
  local file_exists = vim.fn.rpcrequest(
    nvim_instance.job_id,
    "nvim_call_function",
    "filereadable",
    { "output.md" }
  )
  assert.equals(1, file_exists, "output.md should be created")
end)
```

**Then Run Tests:**

```bash
npm run test:e2e
```

**If Fails:** Apply 3-try auto-fix rule.

## Conclusion

By following these procedures, Claude can:

1. Automatically test new features via E2E tests
2. Self-correct errors using the 3-try rule
3. Escalate to user only when truly stuck
4. Maintain high code quality without manual QA burden

Always remember: **Tests must pass before proceeding to code review phase.**
