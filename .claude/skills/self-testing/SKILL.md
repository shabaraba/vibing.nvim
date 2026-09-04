---
name: self-testing
description: E2E self-testing workflow for vibing.nvim using a separate Neovim instance controlled over RPC. Use when writing or debugging E2E tests, running `npm run test:e2e`, or executing the 3-try auto-fix rule after implementing a feature. Covers the spawn_nvim_instance/send_keys/wait_for_buffer_content/wait_for_assistant_turns/cleanup_instance helper API, test scenario checklist, and troubleshooting for hangs, "Job not found", and cross-test state pollution.
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
  │   ├─ wait_for_assistant_turns() - A turn ran and did not fail (start here)
  │   ├─ wait_for_assistant_text()  - Output only the model could produce
  │   ├─ wait_for_response()        - Whole buffer, but aborts when the turn errors
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

## Three Things the Child Neovim Needs

Each of these silently produced a dead spec before — a spec that ran, printed nothing useful and
was never fixed because nothing said it had failed.

- **`--embed`.** `spawn_nvim_instance` starts the child with it, because `jobstart{ rpc = true }`
  talks msgpack-RPC to its stdio. Without it every `rpcrequest` fails and the spec never gets past
  its first wait — which is the state all four specs were in.
- **`tests/e2e_init.lua`, not `tests/minimal_init.lua`.** The latter is the _parent's_ init (it
  wires up plenary); a child started with it has vibing.nvim on `runtimepath` but never calls
  `setup()`, so no `:Vibing*` command exists and `:VibingChat` does nothing. `e2e_init.lua` also
  points `chat.save_dir` at a per-child temp directory, so running the suite stops writing real
  chat files into the repository.
- **`wait_for_buffer_name`, not `wait_for_buffer_content`, for a filename.** The latter matches
  against buffer _text_, so `wait_for_buffer_content(inst, "%.md")` can never match. That one line,
  repeated at six sites, is what every spec was actually failing on.

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
`true`/`false`. Use it for buffer state vibing.nvim writes on its own — frontmatter, a rendered
prompt, a slash command's confirmation. **Not** for anything that depends on a CLI turn.

### Waits that depend on a CLI turn

Three helpers, all returning `ok, reason` — pass `reason` straight into the assertion message —
and all giving up the moment the turn writes `**Error:**`. Never use `wait_for_buffer_content`
for something a turn has to produce: that error text lands under a normal `## … Assistant`
header, so waiting for the header asserts nothing at all.

#### `wait_for_assistant_turns(instance, count, timeout)`

"A turn ran and did not fail." **Start here.** It does not depend on the model choosing to say any
particular thing, so it cannot go flaky on a rewording.

```lua
local ok, reason = helper.wait_for_assistant_turns(nvim_instance, 1, 30000)
assert.is_true(ok, reason or "the assistant should have answered")
```

#### `wait_for_assistant_text(instance, pattern, timeout)`

For content only the model could have produced — the marker word in `plugin_dir_spec`, proving a
skill's description reached it. Matches **only the text after the last `## … Assistant` header**.

That scoping is the whole point. Match the whole buffer instead and a marker word your own prompt
asks for is satisfied by the `## User` section, so the spec passes with the turn never having
returned a byte. Put the marker somewhere the prompt does not repeat — a skill description, a
file the model has to read.

#### `wait_for_response(instance, pattern, timeout)`

Whole buffer, for what the chat UI renders into the **user** section as a result of a turn: the
tool-approval prompt, the `nvim_ask_user_question` choice list.

### `cleanup_instance(instance)`

Stop the Neovim instance job. Always call this in `after_each()`.

### Running as root

`spawn_nvim_instance` sets `IS_SANDBOX=1` for the child when `getuid()` is 0. The E2E init pins
`permissions.mode = "bypassPermissions"`, which becomes `--dangerously-skip-permissions`, and the
CLI refuses that under root — so in a container every spec needing a real turn fails without it.
It is gated on uid rather than set unconditionally: on a developer's own machine there is no root
check to clear, only a safety check to lose.

## Budget: a spec cannot outlast its harness

plenary joins each spec **file** with one timeout — `timeout = 240000` in the `test:e2e` script.
A spec still inside a `vim.wait` when that expires is killed mid-wait and prints **nothing**: no
summary, no failure, no test count. So the sum of every wait a file can perform has to fit inside
that budget, and `tests/e2e-timeout-gate.test.mjs` fails the build when it does not. Raise the
script's `timeout` rather than trimming a wait that a real turn needs.

## 3-Try Auto-Fix Rule

After implementing a feature, run `pnpm run test:e2e`. If it fails: analyze the failure, apply a
targeted fix (implementation or test), and re-run — up to 3 attempts, each based on new analysis of
the latest failure. If it still fails after 3, stop and report to the user: the error, the 3 fixes
tried, the suspected cause, and a suggested next step.

**Do not proceed to code review while E2E tests are failing** — either fix them via the rule above
or escalate.

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

  local ok, reason = helper.wait_for_assistant_turns(nvim_instance, 1, 30000)
  assert.is_true(ok, reason or "Assistant should respond")

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
