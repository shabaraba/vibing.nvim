---
name: self-testing
description: E2E self-testing workflow for vibing.nvim using a separate Neovim instance controlled over RPC. Use when writing or debugging E2E tests, running `npm run test:e2e`, or executing the 3-try auto-fix rule after implementing a feature. Covers the spawn_nvim_instance/send_keys/wait_for_buffer_content/cleanup_instance helper API, test scenario checklist, and troubleshooting for hangs, "Job not found", and cross-test state pollution.
---

# Self-Testing for vibing.nvim

vibing.nvim can test itself by driving a separate, child Neovim instance over RPC. This enables
automatic QA and self-correction after implementing a feature, without manual testing.

## Architecture

```text
Test Runner (Current Nvim)
  ├─ lua/vibing/testing/e2e_helper.lua
  │   ├─ spawn_nvim_instance()  - Launch child Nvim via jobstart(rpc=true)
  │   ├─ send_keys()             - Send key input via rpcrequest
  │   ├─ wait_for_buffer_content() - Poll buffer TEXT until pattern matches
  │   ├─ wait_for_buffer_name()    - Poll buffer NAME (use this for a filename)
  │   └─ cleanup_instance()      - Stop job
  │
  └─ tests/e2e/*.spec.lua - plenary.nvim test specs
       └─ Test Neovim Instance (Child Process)
            └─ vibing.nvim running with test configuration
```

Communication: Parent Nvim ←RPC→ Child Nvim (`jobstart` with `rpc=true`). Child instances get a
unique RPC port in the 9876-9925 range.

## Running Tests

```bash
npm run test:e2e   # all E2E tests (sets VIBING_E2E=1; spends real tokens)
npm test           # unit only (test:lua + test:node) — E2E is deliberately not included

# Specific file. VIBING_E2E=1 is required: without it every spec self-skips, and the run reports
# "0 tests" as a pass rather than telling you nothing ran.
VIBING_E2E=1 nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedFile tests/e2e/chat_jump_user_spec.lua"
```

## Writing a Test

Place files in `tests/e2e/` with a `_spec.lua` suffix:

```lua
local helper = require("vibing.testing.e2e_helper")

describe("E2E: Chat basic flow", function()
  local nvim_instance

  before_each(function()
    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = "tests/e2e_init.lua",
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)  -- always cleanup, prevents zombie processes
  end)

  it("should create chat buffer and display initial state", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(2000)

    local ok = helper.wait_for_buffer_name(nvim_instance, "%.md$", 5000)
    assert.is_true(ok, "Chat buffer should be created with .md extension")

    ok = helper.wait_for_buffer_content(nvim_instance, "created_at:", 2000)
    assert.is_true(ok, "Frontmatter should contain created_at field")
  end)
end)
```

Best practices: fresh instance per test (`before_each`/`after_each`), descriptive assertion
messages, regex-style patterns for flexible matching (e.g. `"## .* Assistant"`), and generous
timeouts for anything that talks to the SDK.

Recommended timeouts: buffer creation 2000-5000ms, frontmatter updates 1000-2000ms, Assistant
responses 30000ms, command execution 1000-2000ms.

## Helper Function Reference

### `spawn_nvim_instance(config)`

Spawn a separate Neovim instance for testing.

- `config.headless` (boolean) - run without UI
- `config.init_script` (string) - path to the _child's_ init. Use `"tests/e2e_init.lua"`:
  `minimal_init.lua` is the parent's and leaves the child without `setup()`, so no `:Vibing*`
  command exists
- `config.cwd` (string, optional) - working directory
- Returns: `instance` table with a `job_id` field

### `send_keys(instance, keys)`

Send a key sequence via `rpcrequest`, e.g. `":VibingChat<CR>"`, `"G"`, `"iHello<Esc>"`.

### `wait_for_buffer_content(instance, pattern, timeout)`

Poll buffer content until `pattern` (Lua pattern) matches or `timeout` (ms) elapses. Returns
`true`/`false`.

### `cleanup_instance(instance)`

Stop the Neovim instance job. Always call this in `after_each()`.

## Test Scenarios to Cover

When implementing a new feature, add E2E coverage for the relevant area:

- **Chat**: buffer creation/initial state, message send + Assistant response, message
  editing/re-sending, `/context` file addition, slash commands (`/mode`, `/model`, `/save`, ...),
  `:VibingChatFork`, multi-turn conversations
- **Worktree skills**: `vibing-worktree-list` via `git worktree list --porcelain`;
  `vibing-worktree-create` creates under `.vibing/worktrees/<branch>/` and rewrites the chat's
  `working_dir` frontmatter; `vibing-worktree-attach` attaches a chat to an existing worktree;
  `vibing-worktree-run` gets a worktree branch running without merge/rebase;
  `vibing-worktree-finish` removes via `git worktree remove` (never `--force`) and clears
  `working_dir` if it was the current chat's own worktree
- **MCP tools**: `nvim_list_instances` returns correct ports, `nvim_chat_send_message` sends to
  the correct chat, LSP tools work against background buffers
- **Permissions**: tool approval UI appears correctly, session-level permissions persist,
  granular rules are enforced

## Test Case Design Workflow

Before implementing E2E tests for a new feature, consider invoking the `/test-design` skill
(`.claude/skills/test-design/SKILL.md`) to generate prioritized scenarios:

```text
/test-design

I implemented [feature description].

Changed files:
- [list of new/modified files]

Existing tests:
- [list of existing test files]
```

It returns Happy path / Error / Edge case / Integration scenarios ranked Critical/High/Medium/Low.
Implement Critical and High priority tests first, saved as `tests/e2e/[feature-name]_spec.lua`.

## Troubleshooting

**Test hangs forever** — the pattern in `wait_for_buffer_content()` never matches. Check it's a
valid Lua pattern (not a plain string or PCRE regex), increase the timeout if the operation is
legitimately slow, or add `print(vim.inspect(lines))` before the pattern check to debug.

**"Job not found" error** — the instance was already cleaned up or failed to start. Verify
`instance.job_id` is valid before RPC calls, check the init script path, and check for errors in
the `on_exit` callback.

**Tests pass individually but fail together** — state pollution between tests. Ensure
`after_each()` cleans up all resources and each test spawns its own fresh instance; don't rely on
global state.

**Child Neovim crashes** — usually an invalid RPC request or timeout. Check the RPC function name
matches Neovim's actual API (e.g. `"nvim_get_current_buf"`, not `"get_current_buf"`) and that
arguments match its signature.

## Example: Testing a New Slash Command

```lua
it("should export chat to markdown file via /export", function()
  helper.send_keys(nvim_instance, ":VibingChat<CR>")
  vim.wait(2000)

  helper.send_keys(nvim_instance, "G")
  helper.send_keys(nvim_instance, "i")
  helper.send_keys(nvim_instance, "Test message")
  helper.send_keys(nvim_instance, "<Esc>")
  helper.send_keys(nvim_instance, "<CR>")

  local ok = helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", 30000)
  assert.is_true(ok, "Assistant should respond")

  helper.send_keys(nvim_instance, "G")
  helper.send_keys(nvim_instance, "i")
  helper.send_keys(nvim_instance, "/export output.md")
  helper.send_keys(nvim_instance, "<Esc>")
  helper.send_keys(nvim_instance, "<CR>")

  ok = helper.wait_for_buffer_content(nvim_instance, "Exported to output.md", 5000)
  assert.is_true(ok, "Export confirmation should appear")

  local file_exists = vim.fn.rpcrequest(
    nvim_instance.job_id, "nvim_call_function", "filereadable", { "output.md" }
  )
  assert.equals(1, file_exists, "output.md should be created")
end)
```
