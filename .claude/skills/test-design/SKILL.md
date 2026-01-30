# Test Design Skill

**Skill Name**: `test-design`
**Invocation**: `/test-design` or `@skill test-design`

## Description

Analyzes newly implemented features and automatically designs comprehensive E2E test cases. Generates test scenarios covering Happy paths, Error cases, Edge cases, and Integration points, along with ready-to-use test code templates.

## When to Use

Invoke this skill **immediately after completing feature implementation** and before running E2E tests:

```
Phase 5: Implementation ✅ (Done)
  ↓
Phase 5.4: Test Case Design 👈 **Call /test-design here**
  ↓
Phase 5.5: Self-Testing (implement generated tests)
  ↓
Phase 6: Code Review
```

## Input

Provide the following context when invoking the skill:

1. **Feature Description**: What did you implement?
2. **Changed Files**: List of new/modified files
3. **Existing Tests**: What tests already exist?

### Example Invocation

```
/test-design

I implemented a new slash command `/export` that exports chat history to Markdown.

Changed files:
- lua/vibing/application/chat/slash_commands.lua (added export_command)
- lua/vibing/utils/markdown_exporter.lua (new file)

Existing tests:
- tests/e2e/chat_basic_flow_spec.lua (basic chat operations)
```

## Output

The skill generates:

### 1. Test Scenario Analysis

Categorized test scenarios with checkboxes:

- **Happy Path** (正常系): Most common use cases
- **Error Cases** (異常系): Error handling scenarios
- **Edge Cases** (境界値): Boundary conditions
- **Integration Points** (連携): Interactions with other features

### 2. Priority Ranking

Tests ranked by importance:

- **Critical**: Must-have for release
- **High**: Error handling, security
- **Medium**: Edge cases, usability
- **Low**: Performance, optimization

### 3. Test Code Templates

Ready-to-implement test code using `e2e_helper.lua`:

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

  -- Generated test cases here
end)
```

## Skill Workflow

### Phase 1: Information Gathering

1. Read changed files to understand implementation
2. Analyze feature scope and dependencies
3. Review existing tests to avoid duplication
4. Identify integration points with other features

### Phase 2: Scenario Design

Generate test scenarios for:

- **Happy Path**: Expected normal behavior
- **Error Cases**: Validation errors, network errors, permission errors, resource errors
- **Edge Cases**: Boundary values, special characters, concurrent execution, timeouts
- **Integration**: Interaction with existing features

### Phase 3: Prioritization

Rank test cases using these criteria:

- **Critical**: Core functionality - system breaks without it
- **High**: Error handling - security risks, data loss prevention
- **Medium**: Usability - edge cases, user experience
- **Low**: Optimization - performance, rare scenarios

### Phase 4: Code Generation

Generate implementation-ready test code:

- plenary.nvim test structure
- `e2e_helper.lua` function calls
- Appropriate timeout constants
- Clear assertion messages

## Tools Used

This skill has access to:

- `Read` - Read implementation files
- `Glob` - Find related files
- `Grep` - Search for patterns
- `LSP` - Analyze code structure

## Example Output

### Feature: `/export` Slash Command

```markdown
## Test Scenario Analysis

### Happy Path ✅

- [ ] Export chat with single message
- [ ] Export chat with multiple messages
- [ ] Export with frontmatter preserved
- [ ] Export to specified file path

### Error Cases ❌

- [ ] Permission denied (read-only directory)
- [ ] Invalid file path (path traversal attack)
- [ ] Empty chat (no messages)
- [ ] Disk full error

### Edge Cases 🔸

- [ ] Very long chat (1000+ messages)
- [ ] Special characters in messages (emoji, control chars)
- [ ] Overwrite existing file
- [ ] Relative vs absolute paths

### Integration Points 🔗

- [ ] Export from worktree chat
- [ ] Export during active Assistant response
- [ ] Export with context files

## Priority Ranking

### Critical

1. Export basic chat successfully
2. Handle permission errors gracefully

### High

3. Validate file path (security)
4. Handle empty chat

### Medium

5. Export with special characters
6. Overwrite confirmation

### Low

7. Performance with 1000+ messages

## Test Code

\`\`\`lua
-- tests/e2e/export_command_spec.lua
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
CHAT_CREATION = 2000,
COMMAND_EXECUTION = 3000,
FILE_CREATION = 1000,
}

describe("E2E: /export command", function()
local nvim_instance
local temp_dir

before_each(function()
nvim_instance = helper.spawn_nvim_instance({
headless = true,
init_script = "tests/minimal_init.lua",
})
temp_dir = vim.fn.tempname()
vim.fn.mkdir(temp_dir, "p")
end)

after_each(function()
helper.cleanup_instance(nvim_instance)
vim.fn.delete(temp_dir, "rf")
end)

it("should export chat to markdown file", function()
-- Create chat
helper.send_keys(nvim_instance, ":VibingChat<CR>")
vim.wait(TIMEOUTS.CHAT_CREATION)

    -- Send a message
    helper.send_keys(nvim_instance, "GiTest message<Esc><CR>")
    local ok = helper.wait_for_buffer_content(
      nvim_instance,
      "## .* Assistant",
      30000
    )
    assert.is_true(ok, "Assistant should respond")

    -- Execute /export command
    local export_path = temp_dir .. "/exported.md"
    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i/export " .. export_path)
    helper.send_keys(nvim_instance, "<Esc><CR>")

    vim.wait(TIMEOUTS.COMMAND_EXECUTION)

    -- Verify file was created
    assert.equals(1, vim.fn.filereadable(export_path), "Export file should exist")

    -- Verify content
    local content = table.concat(vim.fn.readfile(export_path), "\n")
    assert.is_true(content:match("Test message"), "Content should contain user message")

end)

it("should handle permission error gracefully", function()
-- Create chat
helper.send_keys(nvim_instance, ":VibingChat<CR>")
vim.wait(TIMEOUTS.CHAT_CREATION)

    -- Try to export to read-only location
    helper.send_keys(nvim_instance, "Gi/export /root/readonly.md<Esc><CR>")
    vim.wait(TIMEOUTS.COMMAND_EXECUTION)

    -- Verify error message appears
    local ok = helper.wait_for_buffer_content(
      nvim_instance,
      "Error.*permission",
      5000
    )
    assert.is_true(ok, "Error message should appear")

end)

-- Add more test cases for High/Medium priority items...
end)
\`\`\`
```

## Configuration

Optional configuration in `.claude/skill-config.yml`:

```yaml
test-design:
  verbosity: detailed # minimal | detailed | comprehensive
  min_priority: medium # critical | high | medium | low
  generate_code: true # Generate test code templates
  include_examples: true # Include usage examples in output
```

## Best Practices

### ✅ Do

1. **Provide detailed feature description** with expected behavior
2. **List all changed files** (`git diff --name-only`)
3. **Mention existing tests** to avoid duplication
4. **Review generated scenarios** - don't blindly accept
5. **Implement Critical/High tests first** - defer Medium/Low

### ❌ Don't

1. **Use vague descriptions** - "Added some features" ❌
2. **Skip review** - Generated tests are templates, not final code ❌
3. **Implement all tests at once** - Prioritize Critical → High → Medium ❌

## Integration with Self-Testing

After running `/test-design`:

1. **Review** generated test scenarios
2. **Approve** Critical and High priority tests
3. **Implement** approved test cases in `tests/e2e/`
4. **Run** `npm run test:e2e`
5. **Apply** 3-try auto-fix rule if failures occur

## Troubleshooting

### Skill generates irrelevant test cases

**Cause**: Unclear feature description

**Fix**: Provide more specific details about what changed and why

### Generated test code has errors

**Cause**: API mismatch with e2e_helper.lua

**Fix**: Check `lua/vibing/testing/e2e_helper.lua` for current API

### Too many test cases generated

**Cause**: Skill tries to cover all possibilities

**Fix**: Focus on Critical/High priority only

## See Also

- `.claude/rules/self-testing.md` - Self-testing procedures
- `.claude/agents/test-case-designer.md` - Detailed agent documentation
- `lua/vibing/testing/e2e_helper.lua` - E2E helper API
- `tests/e2e/chat_basic_flow_spec.lua` - Example test suite
