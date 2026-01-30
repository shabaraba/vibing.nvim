---
name: test-design
description: Automatically design comprehensive E2E test cases for newly implemented vibing.nvim features. Use immediately after completing feature implementation (Phase 5.4) and before running E2E tests. Generates test scenarios covering Happy paths, Error cases, Edge cases, and Integration points with priority ranking (Critical/High/Medium/Low) and ready-to-use test code templates using e2e_helper.lua.
---

# Test Design for vibing.nvim

Generate comprehensive E2E test scenarios after implementing new features.

## Usage

Provide context when invoking:

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

I implemented a new slash command `/export` that exports chat history to Markdown.

Changed files:
- lua/vibing/application/chat/slash_commands.lua (added export_command)
- lua/vibing/utils/markdown_exporter.lua (new file)

Existing tests:
- tests/e2e/chat_basic_flow_spec.lua (basic chat operations)
```

## Output Format

### 1. Test Scenario Analysis

Categorized scenarios with checkboxes:

- **Happy Path** ✅ - Most common use cases
- **Error Cases** ❌ - Error handling (validation, network, permissions)
- **Edge Cases** 🔸 - Boundary conditions, special characters, timeouts
- **Integration Points** 🔗 - Interactions with other features

### 2. Priority Ranking

- **Critical**: Core functionality - must work for release
- **High**: Error handling - security, data loss prevention
- **Medium**: Usability - edge cases, user experience
- **Low**: Performance - optimization, rare scenarios

### 3. Test Code Templates

Ready-to-implement code using `e2e_helper.lua`:

```lua
describe("E2E: [Feature Name]", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  -- Test cases with appropriate TIMEOUTS constants
end)
```

## Workflow

1. **Gather context** - Read changed files, analyze scope, review existing tests
2. **Design scenarios** - Generate Happy/Error/Edge/Integration cases
3. **Prioritize** - Rank by Critical/High/Medium/Low
4. **Generate code** - Create implementation-ready test templates

## Example Output

For a `/export` command that exports chat to Markdown:

### Test Scenarios

**Happy Path ✅**

- [ ] Export chat with single message
- [ ] Export chat with multiple messages
- [ ] Export with frontmatter preserved

**Error Cases ❌**

- [ ] Permission denied (read-only directory)
- [ ] Invalid file path (path traversal attack)
- [ ] Empty chat (no messages)

**Edge Cases 🔸**

- [ ] Very long chat (1000+ messages)
- [ ] Special characters in messages

**Integration Points 🔗**

- [ ] Export from worktree chat
- [ ] Export during active Assistant response

### Priority Ranking

**Critical**

1. Export basic chat successfully
2. Handle permission errors gracefully

**High**

3. Validate file path (security)
4. Handle empty chat

**Medium**

5. Export with special characters

### Test Code

```lua
-- tests/e2e/export_command_spec.lua
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  COMMAND_EXECUTION = 3000,
}

describe("E2E: /export command", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/minimal_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
  end)

  it("should export chat to markdown file", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    helper.send_keys(nvim_instance, "GiTest message<Esc><CR>")
    local ok = helper.wait_for_buffer_content(
      nvim_instance,
      "## .* Assistant",
      30000
    )
    assert.is_true(ok, "Assistant should respond")

    -- Execute /export and verify...
  end)
end)
```

## Best Practices

**Do:**

- Provide detailed feature description with expected behavior
- List all changed files (`git diff --name-only`)
- Review generated scenarios - don't blindly accept
- Implement Critical/High tests first

**Don't:**

- Use vague descriptions ("Added some features")
- Skip review - templates need customization
- Implement all tests at once - prioritize

## Next Steps

After running `/test-design`:

1. Review generated test scenarios
2. Approve Critical and High priority tests
3. Implement approved tests in `tests/e2e/`
4. Run `npm run test:e2e`
5. Apply 3-try auto-fix rule if failures occur (see `.claude/rules/self-testing.md`)

## References

- `.claude/rules/self-testing.md` - Complete self-testing procedures
- `lua/vibing/testing/e2e_helper.lua` - E2E helper API reference
- `tests/e2e/chat_basic_flow_spec.lua` - Example test suite
