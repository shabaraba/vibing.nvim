# Worktree Native Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace vibing.nvim's custom `.vibing/workspace/<id>/` worktree lifecycle
(`scripts/vibing-workspace.mjs` + 5 `vibing-workspace-*` skills + `meta.yaml`/`plan.md`
bookkeeping) with a thin, natural-language-driven approach built on plain `git worktree`
commands and the chat file's own `working_dir` frontmatter.

**Architecture:** One new bundled skill (`vibing-worktree`) documents four Bash/Edit-tool
recipes — list, create, attach, finish — operating on a flat `.vibing/worktrees/<branch-name>/`
directory layout with no metadata files. A system-prompt addition tells Claude the directory
convention. The dead `nvim_chat_worktree` MCP tool and all workspace-bookkeeping code
(script, skills, mote path-matching) are deleted.

**Tech Stack:** Lua (Neovim plugin), TypeScript (MCP server, vitest), plenary.nvim/busted (Lua
tests), Markdown (skill/docs).

## Global Constraints

- No SDK dependency reintroduction — `@anthropic-ai/claude-agent-sdk` stays out of
  `package.json`. (Rejected in design: see
  `docs/superpowers/specs/2026-07-10-worktree-native-redesign-design.md`, "Rejected approaches".)
- No `--worktree` CLI flag delegation for worktree creation — always plain
  `git worktree add -b <branch> <path>`. (Same design section.)
- `git worktree remove` must never be called with `--force` anywhere in this codebase or the new
  skill's documented recipe.
- New worktree path convention is exactly `.vibing/worktrees/<branch-name>/` — flat, no counter
  prefix, no nested `worktree/` subdirectory, no `meta.yaml`, no `plan.md`.
- No automatic migration tooling for pre-existing `.vibing/workspace/<id>/` workspaces.

---

### Task 1: System prompt — worktree directory convention

**Files:**

- Modify: `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua:148-160`
- Test: `tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua` (new)

**Interfaces:**

- Consumes: nothing new — `M.build(prompt, opts, session_id, config, settings_path)` keeps its
  existing signature.
- Produces: nothing new for other tasks — this is a leaf change.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua`:

```lua
local cli_command_builder = require("vibing.infrastructure.adapter.modules.cli_command_builder")

describe("cli_command_builder", function()
  local original_exepath

  before_each(function()
    original_exepath = vim.fn.exepath
    vim.fn.exepath = function(name)
      if name == "claude" then
        return "/usr/local/bin/claude"
      end
      return original_exepath(name)
    end
  end)

  after_each(function()
    vim.fn.exepath = original_exepath
  end)

  local function find_flag(cmd, flag)
    for i, arg in ipairs(cmd) do
      if arg == flag then
        return i
      end
    end
    return nil
  end

  describe("system prompt", function()
    it("always appends the worktree directory convention instruction", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(prompt_text:find(".vibing/worktrees/", 1, true) ~= nil)
    end)

    it("combines the language instruction and worktree instruction into a single flag", function()
      local config = { language = "ja" }
      local cmd = cli_command_builder.build("hello", {}, nil, config, nil)

      local count = 0
      local prompt_text = nil
      for i, arg in ipairs(cmd) do
        if arg == "--append-system-prompt" then
          count = count + 1
          prompt_text = cmd[i + 1]
        end
      end

      assert.equals(1, count)
      assert.is_true(prompt_text:find("Japanese", 1, true) ~= nil)
      assert.is_true(prompt_text:find(".vibing/worktrees/", 1, true) ~= nil)
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:lua`
Expected: FAIL — `cli_command_builder_spec.lua` fails because the worktree instruction isn't in
the system prompt yet (the "always appends" test fails since today's code only inserts
`--append-system-prompt` when a non-English language is configured).

- [ ] **Step 3: Write minimal implementation**

In `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`, replace lines 148-160
(the "Language as system prompt append" block through the `--setting-sources` insertion):

```lua
  -- System prompt additions (worktree convention + optional language instruction)
  local system_prompt_lines = {
    "When creating a git worktree for isolated work, place it under "
      .. ".vibing/worktrees/<branch-name>/ at the repository root.",
  }

  local language = resolve_language(opts, config)
  if language and language ~= "en" then
    local language_utils = require("vibing.core.utils.language")
    local lang_name = language_utils.language_names[language]
    if lang_name then
      table.insert(system_prompt_lines, 1, string.format("Always respond in %s (%s).", lang_name, language))
    end
  end

  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, table.concat(system_prompt_lines, "\n"))

  table.insert(cmd, "--setting-sources")
  table.insert(cmd, "user,project,local")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua
git commit -m "feat: tell Claude the .vibing/worktrees/ convention via system prompt"
```

---

### Task 2: mote context naming for the new worktree path

**Files:**

- Modify: `lua/vibing/core/utils/mote/context.lua:30-66`
- Test: `tests/lua/core/utils/mote/context_spec.lua` (new)

**Interfaces:**

- Consumes: nothing new.
- Produces: `Context.build_name(context_prefix, cwd)` — unchanged signature and return type
  (string), only the path pattern it recognizes changes. Task 3 does not call this function, so
  no cross-task interface dependency.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/core/utils/mote/context_spec.lua`:

```lua
local Context = require("vibing.core.utils.mote.context")

describe("mote context", function()
  describe("build_name", function()
    it("returns a worktree-scoped name for a cwd under .vibing/worktrees/<branch>", function()
      local name = Context.build_name("vibing", "/repo/.vibing/worktrees/fix-auth-session-bug")
      assert.is_true(name:match("^vibing%-worktree%-fix%-auth%-session%-bug%-%x%x%x%x%x%x%x%x$") ~= nil)
    end)

    it("is stable for the same branch name", function()
      local first = Context.build_name("vibing", "/repo/.vibing/worktrees/my-branch")
      local second = Context.build_name("vibing", "/repo/.vibing/worktrees/my-branch")
      assert.equals(first, second)
    end)

    it("falls back to <prefix>-root when cwd is not under .vibing/worktrees/", function()
      assert.equals("vibing-root", Context.build_name("vibing", "/repo"))
    end)

    it("falls back to <prefix>-root when cwd is nil", function()
      assert.equals("vibing-root", Context.build_name("vibing", nil))
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:lua`
Expected: FAIL — the first two assertions fail because `build_name` still only recognizes
`.vibing/workspace/{active,done}/<id>/worktree` and `.worktrees/<branch>/`, not
`.vibing/worktrees/<branch>`.

- [ ] **Step 3: Write minimal implementation**

In `lua/vibing/core/utils/mote/context.lua`, replace lines 30-66 (from the `M.build_name`
doc comment through the end of the function):

```lua
---Worktree固有のコンテキスト名を生成
---mote v0.2.4: --context API対応
---
---同じworktree内の全セッションは同じmote contextを共有します。
---これにより、worktree内での作業履歴を一貫して追跡できます。
---
---衝突防止のため、ブランチ名のハッシュをサフィックスとして追加します。
---例: .vibing/worktrees/feature-task → vibing-worktree-feature-task-a1b2c3d4
---
---@param context_prefix string コンテキスト名のプレフィックス
---@param cwd? string 作業ディレクトリ（worktree判定用）
---@return string Worktree固有のコンテキスト名
function M.build_name(context_prefix, cwd)
  if cwd then
    local branch_name = cwd:match("%.vibing/worktrees/([^/]+)")
    if branch_name then
      local worktree_name = sanitize_name(branch_name)
      local hash_suffix = generate_hash(branch_name)
      return string.format("%s-worktree-%s-%s", context_prefix, worktree_name, hash_suffix)
    end
  end

  return string.format("%s-root", context_prefix)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:lua`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/core/utils/mote/context.lua tests/lua/core/utils/mote/context_spec.lua
git commit -m "refactor: match .vibing/worktrees/<branch> in mote context naming"
```

---

### Task 3: Simplify mote ignore-file handling for the new layout

**Files:**

- Modify: `lua/vibing/core/utils/mote/moteignore.lua:1-130`
- Modify: `lua/vibing/core/utils/mote/operations.lua:122,143,147`
- Test: `tests/lua/core/utils/mote/moteignore_spec.lua` (new)

**Interfaces:**

- Consumes: nothing new.
- Produces: `Moteignore.add_vibing_ignore(context_dir)` — signature changes from
  `(context_dir, cwd)` to `(context_dir)`. `operations.lua` is the only other caller in the
  codebase and is updated in this same task.

Since worktrees now always live under `.vibing/worktrees/`, they're already covered by the
existing `.vibing/` ignore entry — the old top-level `.worktrees/`-specific ignore rule (added
only when `cwd` was _not_ inside a worktree) is now dead code. This task removes that branch and
the now-unused `cwd` parameter along with it.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/core/utils/mote/moteignore_spec.lua`:

```lua
local Moteignore = require("vibing.core.utils.mote.moteignore")

describe("moteignore", function()
  local tmp_dir

  before_each(function()
    tmp_dir = vim.fn.tempname()
    vim.fn.mkdir(tmp_dir, "p")
  end)

  after_each(function()
    vim.fn.delete(tmp_dir, "rf")
  end)

  describe("add_vibing_ignore", function()
    it("adds .vibing/ (and never a separate .worktrees/ rule) to an ignore file lacking it", function()
      local ignore_path = tmp_dir .. "/ignore"
      vim.fn.writefile({
        "# Uses gitignore syntax",
        "",
        "node_modules/",
      }, ignore_path)

      Moteignore.add_vibing_ignore(tmp_dir)

      local content = table.concat(vim.fn.readfile(ignore_path), "\n")
      assert.is_true(content:match("%.vibing/") ~= nil)
      assert.is_nil(content:match("%.worktrees/"))
    end)

    it("does not duplicate .vibing/ if already present", function()
      local ignore_path = tmp_dir .. "/ignore"
      vim.fn.writefile({
        "# Uses gitignore syntax",
        "",
        ".vibing/",
      }, ignore_path)

      Moteignore.add_vibing_ignore(tmp_dir)

      local lines = vim.fn.readfile(ignore_path)
      local count = 0
      for _, line in ipairs(lines) do
        if line == ".vibing/" then
          count = count + 1
        end
      end
      assert.equals(1, count)
    end)

    it("does nothing when the ignore file does not exist", function()
      Moteignore.add_vibing_ignore(tmp_dir)
      assert.equals(0, vim.fn.filereadable(tmp_dir .. "/ignore"))
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `npm run test:lua`
Expected: FAIL — against today's implementation, calling `add_vibing_ignore(tmp_dir)` with one
argument passes `cwd = nil`, which today's `is_worktree(nil)` treats as "not inside a worktree",
so the current code still adds a separate `.worktrees/` ignore entry (since that entry is only
skipped when `cwd` places you _inside_ a worktree). The new
`assert.is_nil(content:match("%.worktrees/"))` assertion fails against that behavior.

- [ ] **Step 3: Write minimal implementation**

In `lua/vibing/core/utils/mote/moteignore.lua`, replace the whole file with:

```lua
---@class Vibing.Utils.Mote.Moteignore
---.moteignoreファイルの管理
local M = {}

---デフォルトの.moteignoreルール
M.DEFAULT_RULES = {
  "# vibing.nvim auto-generated .moteignore",
  "# Ignore .vibing directory contents (vibing.nvim internal files)",
  ".vibing/",
  "",
  "# Dependencies (large file count, causes slow snapshots)",
  "node_modules/",
  "**/node_modules/",
  "",
  "# Build outputs",
  "dist/",
  "build/",
  "",
  "# Version control",
  ".git/",
  "",
  "# Common cache/artifact directories",
  ".cache/",
  "coverage/",
  ".nyc_output/",
  "__pycache__/",
  "*.pyc",
  ".pytest_cache/",
  "target/",
  "",
}

---.moteignoreファイルが存在しない場合は自動作成
---@param ignore_file_path string .moteignoreファイルのパス
function M.ensure_exists(ignore_file_path)
  local abs_path = vim.fn.fnamemodify(ignore_file_path, ":p")

  if vim.fn.filereadable(abs_path) == 1 then
    return
  end

  local parent_dir = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(parent_dir, "p")

  vim.fn.writefile(M.DEFAULT_RULES, abs_path)
end

---コンテキストのignoreファイルに.vibing/を追加
---worktreeは常に.vibing/worktrees/配下に作られるため、.vibing/を無視すれば
---worktree自体も自動的に無視される（.worktrees/専用のルールはもう不要）
---@param context_dir string コンテキストディレクトリのパス
function M.add_vibing_ignore(context_dir)
  local ignore_file_path = context_dir .. "/ignore"
  local ignore_file = io.open(ignore_file_path, "r")
  if not ignore_file then
    return
  end

  local content = ignore_file:read("*all")
  ignore_file:close()

  if content:match("%.vibing/") ~= nil then
    return
  end

  local lines = vim.split(content, "\n")
  local insert_pos = nil

  for i, line in ipairs(lines) do
    if line:match("^# Uses gitignore syntax") then
      insert_pos = i + 1
      break
    end
  end

  if not insert_pos then
    return
  end

  while insert_pos <= #lines and lines[insert_pos] == "" do
    insert_pos = insert_pos + 1
  end

  local entries_to_add = { "", "# vibing.nvim internal files", ".vibing/" }

  for i, entry in ipairs(entries_to_add) do
    table.insert(lines, insert_pos + i - 1, entry)
  end

  local new_content = table.concat(lines, "\n")
  local write_file = io.open(ignore_file_path, "w")
  if write_file then
    write_file:write(new_content)
    write_file:close()
  end
end

return M
```

Then update the three call sites in `lua/vibing/core/utils/mote/operations.lua`:

Replace line 122:

```lua
      Moteignore.add_vibing_ignore(context_dir, config.cwd)
```

with:

```lua
      Moteignore.add_vibing_ignore(context_dir)
```

Replace line 143:

```lua
    Moteignore.add_vibing_ignore(context_dir, config.cwd)
```

with:

```lua
    Moteignore.add_vibing_ignore(context_dir)
```

Replace line 147:

```lua
    Moteignore.add_vibing_ignore(context_dir, config.cwd)
```

with:

```lua
    Moteignore.add_vibing_ignore(context_dir)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `npm run test:lua`
Expected: PASS

- [ ] **Step 4b: Confirm no remaining two-argument call sites**

Run: `grep -rn "add_vibing_ignore(" lua/`
Expected: every call shows exactly one argument (`context_dir`), no `config.cwd` or other second
argument remaining.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/core/utils/mote/moteignore.lua lua/vibing/core/utils/mote/operations.lua tests/lua/core/utils/mote/moteignore_spec.lua
git commit -m "refactor: drop dead .worktrees/ ignore-rule branch now covered by .vibing/"
```

---

### Task 4: Remove the dead `nvim_chat_worktree` MCP tool

**Files:**

- Modify: `mcp-server/src/tools/chat.ts`
- Modify: `mcp-server/src/handlers/chat.ts`
- Modify: `mcp-server/src/handlers/index.ts:49`
- Test: `mcp-server/src/__tests__/chat-tools.test.ts` (new)

**Interfaces:**

- Consumes: nothing new.
- Produces: nothing new for other tasks. `chatTools` (from `tools/chat.ts`) and `handlers` (from
  `handlers/index.ts`) keep their existing shapes minus the removed entries;
  `handleChatSendMessage`/`nvim_chat_send_message` are untouched.

- [ ] **Step 1: Write the failing test**

Create `mcp-server/src/__tests__/chat-tools.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { allTools } from '../tools/index.js';
import { handlers } from '../handlers/index.js';

describe('chat tools (worktree redesign)', () => {
  it('does not register nvim_chat_worktree', () => {
    const names = allTools.map((tool) => tool.name);
    expect(names).not.toContain('nvim_chat_worktree');
  });

  it('still registers nvim_chat_send_message', () => {
    const names = allTools.map((tool) => tool.name);
    expect(names).toContain('nvim_chat_send_message');
  });

  it('does not have a handler for nvim_chat_worktree', () => {
    expect(handlers.nvim_chat_worktree).toBeUndefined();
  });

  it('still has a handler for nvim_chat_send_message', () => {
    expect(handlers.nvim_chat_send_message).toBeDefined();
    expect(typeof handlers.nvim_chat_send_message).toBe('function');
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd mcp-server && npx vitest run src/__tests__/chat-tools.test.ts`
Expected: FAIL — the first and third assertions fail because `nvim_chat_worktree` is still
registered.

- [ ] **Step 3: Write minimal implementation**

Replace the full contents of `mcp-server/src/tools/chat.ts` with:

```ts
import type { Tool } from '@modelcontextprotocol/sdk/types.js';

/**
 * Chat-related MCP tools
 */

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_send_message',
    description:
      'Programmatically send a message to a chat buffer and trigger AI request. ' +
      'Useful for multi-agent workflows where one Claude instance sends messages to another.',
    inputSchema: {
      type: 'object',
      properties: {
        bufnr: {
          type: 'number',
          description: 'Buffer number of the target chat buffer',
        },
        message: {
          type: 'string',
          description: 'Message content to send',
        },
        sender: {
          type: 'string',
          description:
            'Optional sender identifier (default: "User"). Future: supports "Alpha", "Bravo", etc.',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
      required: ['bufnr', 'message'],
    },
  },
];
```

Replace the full contents of `mcp-server/src/handlers/chat.ts` with:

```ts
import { callNeovim } from '../rpc.js';
import { z } from 'zod';

// Zod schemas for validation
const chatSendMessageArgsSchema = z.object({
  bufnr: z.number(),
  message: z.string(),
  sender: z.string().optional(),
  rpc_port: z.number().optional(),
});

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const { bufnr, message, sender, rpc_port } = chatSendMessageArgsSchema.parse(args);

  await callNeovim('send_message', { bufnr, message, sender }, rpc_port);

  return {
    content: [{ type: 'text', text: 'Message sent and AI request initiated in chat buffer' }],
    _meta: { bufnr, sender: sender || 'User' },
  };
}
```

In `mcp-server/src/handlers/index.ts`, remove line 49:

```ts
  nvim_chat_worktree: chat.handleChatWorktree,
```

so the "Chat operations" block (lines 48-51) reads:

```ts
  // Chat operations
  nvim_chat_send_message: chat.handleChatSendMessage,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd mcp-server && npx vitest run`
Expected: PASS (all suites, including the new `chat-tools.test.ts` and the existing
`tool-registry.test.ts`, `execute.test.ts`, `instances.test.ts`, `rpc-client.test.ts`,
`schema.test.ts`)

- [ ] **Step 5: Commit**

```bash
git add mcp-server/src/tools/chat.ts mcp-server/src/handlers/chat.ts mcp-server/src/handlers/index.ts mcp-server/src/__tests__/chat-tools.test.ts
git commit -m "fix: remove dead nvim_chat_worktree MCP tool"
```

---

### Task 5: Delete the old workspace script and skills

**Files:**

- Delete: `scripts/vibing-workspace.mjs`
- Delete: `skills/vibing-workspace/SKILL.md` (and the now-empty `skills/vibing-workspace/`
  directory)
- Delete: `skills/vibing-workspace-create/SKILL.md` (and directory)
- Delete: `skills/vibing-workspace-enter/SKILL.md` (and directory)
- Delete: `skills/vibing-workspace-done/SKILL.md` (and directory)
- Delete: `skills/vibing-workspace-list/SKILL.md` (and directory)

**Interfaces:**

- Consumes: nothing.
- Produces: nothing — pure deletion. Task 6 creates the replacement skill separately.

- [ ] **Step 1: Delete the files**

```bash
git rm -r scripts/vibing-workspace.mjs skills/vibing-workspace skills/vibing-workspace-create skills/vibing-workspace-enter skills/vibing-workspace-done skills/vibing-workspace-list
```

- [ ] **Step 2: Verify nothing else in source references the deleted script**

Run: `grep -rn "vibing-workspace.mjs" --include="*.lua" --include="*.ts" --include="*.mjs" .`
Expected: no output (docs references are handled in Tasks 7-8, not source code).

- [ ] **Step 3: Commit**

```bash
git commit -m "chore: remove the old .vibing/workspace worktree lifecycle"
```

---

### Task 6: Add the `vibing-worktree` skill

**Files:**

- Create: `skills/vibing-worktree/SKILL.md`

**Interfaces:**

- Consumes: the `.vibing/worktrees/<branch-name>/` convention from Task 1's system prompt line
  (documents the same convention so the two stay in sync).
- Produces: nothing consumed by other tasks in this plan — Tasks 7-8 reference this skill's name
  and location in prose, not its content.

- [ ] **Step 1: Write the skill**

Create `skills/vibing-worktree/SKILL.md`:

````markdown
---
name: vibing-worktree
description: Create, list, attach to, and finish git-worktree-backed isolated work areas for vibing.nvim chats, entirely via natural language — no separate UI. Use when the user wants to isolate work in its own worktree ("split this into its own worktree", "start this in isolation"), wants to see what worktrees/branches exist ("what worktrees do I have", "what's in progress"), wants to switch/attach the current or a new chat to an existing worktree ("let's go into the auth-fix worktree", "attach to worktree X"), or wants to clean one up when done ("clean up this worktree", "I'm done with this branch's worktree").
---

# vibing-worktree

Git worktrees provide isolated working directories for parallel development. This skill uses
plain `git` commands and this chat's own frontmatter — no bespoke helper script, no metadata
file. A worktree's existence on disk is its entire state.

## Directory convention

Worktrees created for isolated work go under `.vibing/worktrees/<branch-name>/` at the git
root — flat, one worktree per directory, nothing else stored alongside it. This convention is
also stated in every vibing.nvim chat's system prompt; follow it so `git worktree list` stays
predictable for later listing.

## List — "what worktrees exist?"

```bash
git worktree list --porcelain
```
````

For a one-line hint of what was last done on a given worktree's branch:

```bash
git log -1 --format=%s <branch>
```

This shows every worktree registered against the repo, not just ones under
`.vibing/worktrees/` — including ones created outside vibing.nvim entirely (a bare
`git worktree add`, or `claude --worktree` run directly in a terminal). Present branch, path,
and (if you fetched it) the last commit message so the user can pick one, whether they're asking
out of curiosity or as a lead-in to attaching.

## Create — "split this off into its own worktree"

1. Derive a short, English, lowercase, kebab-case branch name from the task being discussed
   (e.g. "認証セッションのバグを直したい" → `fix-auth-session-bug`). Confirm it with the user if
   the mapping isn't obvious — a wrong name is annoying to rename later.
2. Create the worktree:

   ```bash
   git worktree add -b <branch> .vibing/worktrees/<branch>
   ```

   If this fails (branch already checked out elsewhere, etc.), the error is self-explanatory —
   surface it verbatim rather than retrying blindly with a different name.

3. Find this chat's own file path. If the `vibing-nvim` MCP server is connected, call
   `mcp__vibing-nvim__nvim_get_info` to get it.
4. Edit that file's frontmatter, setting:

   ```yaml
   working_dir: .vibing/worktrees/<branch>
   ```

   (relative to the git root). Don't open a new chat buffer — the current conversation continues,
   and its next turn already runs in the new worktree.

5. If `nvim_get_info` isn't available (no `vibing-nvim` MCP connection), tell the user the
   worktree is ready at `.vibing/worktrees/<branch>` and that they'll need to set `working_dir`
   in the chat's frontmatter by hand (or open a new chat there) to actually start using it.

## Attach — "what worktrees are there? — let's go into the auth one"

Works the same whether this is a brand-new chat's first exchange or mid-conversation in an
existing one.

1. Run the **List** steps above to surface candidates.
2. Once the user picks one, follow **Create** steps 3-5 to point this chat's own `working_dir`
   frontmatter at the chosen worktree's path — the worktree already exists, so skip the
   `git worktree add` step.

## Finish — "clean up this worktree"

```bash
git worktree remove <path>
```

Never add `--force`. If git refuses because of uncommitted changes, that's it protecting the
user from losing work — report the exact error and let them decide whether to commit, stash, or
discard those changes themselves, rather than retrying with `--force` on their behalf.

If the removed path was this chat's own `working_dir`, clear that frontmatter field once removal
succeeds (reverting to the main repo root) — leaving it pointed at a now-deleted directory would
break the next turn.

````

- [ ] **Step 2: Verify frontmatter and markdown lint pass**

Run: `npm run lint:md`
Expected: no errors reported for `skills/vibing-worktree/SKILL.md`.

- [ ] **Step 3: Commit**

```bash
git add skills/vibing-worktree/SKILL.md
git commit -m "feat: add vibing-worktree skill for natural-language worktree management"
````

---

### Task 7: Update project docs to reference the new skill and layout

**Files:**

- Modify: `.claude/rules/commands-reference.md`
- Modify: `.claude/rules/architecture.md`
- Modify: `.claude/rules/self-testing.md`
- Modify: `.claude/rules/self-development.md`
- Modify: `README.md`

**Interfaces:** none — documentation only.

- [ ] **Step 1: Update `.claude/rules/commands-reference.md`**

Replace:

```markdown
Workspace lifecycle (create/enter/done/list worktree-backed workspaces) is handled by the
`vibing-workspace-*` Claude Code skills bundled with this plugin (`skills/`), not by chat slash
commands. See the plugin's `skills/vibing-workspace/SKILL.md` for the shared reference and the
four `skills/vibing-workspace-*/SKILL.md` skills for each operation.
```

with:

```markdown
Worktree lifecycle (list/create/attach/finish) is handled entirely through natural-language
requests backed by the `vibing-worktree` Claude Code skill bundled with this plugin (`skills/`),
not by chat slash commands. See `skills/vibing-worktree/SKILL.md`.
```

- [ ] **Step 2: Update `.claude/rules/architecture.md`**

Replace the "Git Worktree Integration" section:

```markdown
## Git Worktree Integration

Worktree-backed development goes through the `vibing-workspace-*` Claude Code skills bundled
with this plugin (`skills/vibing-workspace-create`, `-enter`, `-done`, `-list`), not through a
vibing.nvim chat command. Workspace directories, including the git worktree itself, live under
`.vibing/workspace/<id>/` (a workspace is "done" once its `worktree/` subdirectory has been
removed). See `skills/vibing-workspace/SKILL.md` for the shared
directory layout and `meta.yaml` schema, and `scripts/vibing-workspace.mjs` for the bundled
script that manages workspace creation/removal.
```

with:

```markdown
## Git Worktree Integration

Worktree-backed development goes through natural-language requests backed by the
`vibing-worktree` Claude Code skill bundled with this plugin (`skills/vibing-worktree`), not
through a vibing.nvim chat command. There is no bespoke lifecycle script or metadata file —
worktrees are created with plain `git worktree add -b <branch> .vibing/worktrees/<branch>/` and
removed with `git worktree remove`; a worktree's existence on disk is its entire state. The
chat's own `working_dir` frontmatter field (unchanged by this) is what keeps a conversation
attached to its worktree across turns. See `skills/vibing-worktree/SKILL.md` for the full
list/create/attach/finish workflow.
```

- [ ] **Step 3: Update `.claude/rules/self-testing.md`**

Replace:

```markdown
### Workspace Features

- [ ] `vibing-workspace-create` skill creates a workspace (worktree + meta.yaml + plan.md)
- [ ] `vibing-workspace-enter` skill registers an existing chat against an active workspace
- [ ] `vibing-workspace-done` skill removes the worktree and moves the workspace to done
- [ ] `vibing-workspace-list` skill lists active and done workspaces
```

with:

```markdown
### Worktree Features

- [ ] `vibing-worktree` skill lists worktrees via `git worktree list --porcelain`
- [ ] `vibing-worktree` skill creates a worktree under `.vibing/worktrees/<branch>/` and rewrites
      the current chat's `working_dir` frontmatter
- [ ] `vibing-worktree` skill attaches a chat (new or existing) to an already-existing worktree
- [ ] `vibing-worktree` skill removes a worktree via `git worktree remove` (never `--force`) and
      clears `working_dir` if it was the current chat's own worktree
```

- [ ] **Step 4: Update `.claude/rules/self-development.md`**

Replace:

```markdown
**For Feature Development:**

1. Use the `vibing-workspace-create` skill instead of manual `git worktree` commands
   - Automatically creates an isolated development environment (worktree + `meta.yaml` + `plan.md`)
   - Use `vibing-workspace-enter` to bind another chat to an existing active workspace
   - Use `vibing-workspace-done` to remove the worktree and move the workspace to done
   - Use `vibing-workspace-list` to list active (or done) workspaces
```

with:

```markdown
**For Feature Development:**

1. Use the `vibing-worktree` skill for isolated development environments — ask in natural
   language ("split this off into its own worktree", "what worktrees exist", "attach to the
   auth-fix worktree", "clean up this worktree"). It runs plain `git worktree` commands under
   `.vibing/worktrees/<branch>/` and updates the current chat's `working_dir` frontmatter; there
   is no separate metadata file or lifecycle state to manage.
```

Also replace the "Mistake 1" entry in the "Common Mistakes and How to Fix Them" section:

```markdown
**Mistake 1: Using `git worktree` instead of the `vibing-workspace-create` skill**

- ❌ Wrong: `git worktree add .worktrees/feature-branch`
- ✅ Correct: invoke the `vibing-workspace-create` skill
- Why: Manual git worktree doesn't create the workspace's `meta.yaml`/`plan.md`
```

with:

```markdown
**Mistake 1: Placing a worktree outside `.vibing/worktrees/`**

- ❌ Wrong: `git worktree add ../feature-branch` or `git worktree add .worktrees/feature-branch`
- ✅ Correct: `git worktree add -b feature-branch .vibing/worktrees/feature-branch` (what the
  `vibing-worktree` skill's "Create" recipe does), then update the chat's `working_dir`
  frontmatter to match
- Why: `.vibing/worktrees/` is the convention every vibing.nvim chat is told about via its system
  prompt, and it's already covered by the `.vibing/` mote-ignore rule; a worktree placed elsewhere
  won't be picked up by that convention and needs its own ignore handling
```

Also update the "Example Development Workflow" code comment:

```typescript
// 1. Create a workspace for new feature (invoke the vibing-workspace-create skill directly,
//    it uses scripts/vibing-workspace.mjs and git worktree under the hood)
```

with:

```typescript
// 1. Create an isolated worktree for the new feature (invoke the vibing-worktree skill's
//    "Create" recipe directly — plain `git worktree add` under .vibing/worktrees/<branch>/)
```

- [ ] **Step 5: Update `README.md`**

Replace:

```markdown
- **Workspace lifecycle** - Use the `vibing-workspace-create`, `vibing-workspace-enter`, `vibing-workspace-done`, and `vibing-workspace-list` Claude Code skills bundled with this plugin to create or reuse a git worktree with trackable lifecycle state.
```

with:

```markdown
- **Worktree lifecycle** - Use the `vibing-worktree` Claude Code skill bundled with this plugin, entirely via natural language, to list/create/attach/finish git worktrees under `.vibing/worktrees/<branch>/`.
```

Replace:

```markdown
Workspace lifecycle is handled by the `vibing-workspace-*` Claude Code skills bundled with this
plugin, not by chat slash commands — see `skills/vibing-workspace/SKILL.md`.
```

with:

```markdown
Worktree lifecycle is handled by the `vibing-worktree` Claude Code skill bundled with this
plugin, not by chat slash commands — see `skills/vibing-worktree/SKILL.md`.
```

- [ ] **Step 6: Verify markdown lint passes**

Run: `npm run lint:md`
Expected: no errors reported for the five modified files.

- [ ] **Step 7: Commit**

```bash
git add .claude/rules/commands-reference.md .claude/rules/architecture.md .claude/rules/self-testing.md .claude/rules/self-development.md README.md
git commit -m "docs: update worktree docs for the vibing-worktree skill"
```

---

### Task 8: Rewrite the worktree E2E test scenario doc

**Files:**

- Modify: `docs/e2e-tests/08-worktree-integration.md`

**Interfaces:** none — documentation only. This doc already describes a stale
`/vibing-workspace-*` slash-command style and an `active`/`done` split that doesn't match even
the pre-redesign implementation (which used a flat `<id>/worktree`, not `active/<id>/worktree`
and `done/<id>/worktree`); this task replaces it wholesale rather than patching it.

- [ ] **Step 1: Replace the file**

Replace the full contents of `docs/e2e-tests/08-worktree-integration.md` with:

```markdown
# E2E Test Scenarios: Worktree Integration (`vibing-worktree` skill)

These scenarios exercise the `vibing-worktree` skill's four natural-language flows against a
real chat session. Each scenario assumes a fresh chat in a git repository with at least one
commit, and that the `vibing-nvim` MCP server is connected unless a scenario says otherwise.

## 1. List worktrees

**Steps:**

1. In a chat, send: "what worktrees exist in this repo right now?"
2. Observe Claude run `git worktree list --porcelain` (and optionally `git log -1 --format=%s`
   per branch) via the Bash tool.

**Expected:**

- Claude presents the current worktree(s) — at minimum the main repo checkout — without erroring
  even if `.vibing/worktrees/` doesn't exist yet.

## 2. Create a worktree and continue in the same chat

**Steps:**

1. In a chat, send: "let's split fixing the auth session bug off into its own worktree."
2. Observe Claude propose a branch name (e.g. `fix-auth-session-bug`), run
   `git worktree add -b fix-auth-session-bug .vibing/worktrees/fix-auth-session-bug`, then edit
   its own chat file's `working_dir` frontmatter field.
3. Send a follow-up message, e.g. "what directory are you in now?"

**Expected:**

- `.vibing/worktrees/fix-auth-session-bug/` exists on disk (`git worktree list --porcelain`
  shows it).
- The chat file's frontmatter now has `working_dir: .vibing/worktrees/fix-auth-session-bug`.
- The follow-up message's response reflects the new worktree's directory, not the main repo root.
- No new chat buffer was opened — the same chat file continued.

## 3. Attach a new chat to an existing worktree

**Steps:**

1. With the worktree from Scenario 2 still present, open a brand-new chat.
2. Send: "what worktrees are there? I want to go into the auth one."

**Expected:**

- Claude lists the existing worktree(s), including `fix-auth-session-bug`.
- After the user confirms, Claude edits the new chat's own `working_dir` frontmatter to
  `.vibing/worktrees/fix-auth-session-bug` (no `git worktree add` — it already exists).
- A follow-up message in this new chat operates in that worktree.

## 4. Finish a worktree — clean removal

**Steps:**

1. In the worktree-attached chat from Scenario 2 or 3, commit or discard any changes so the
   worktree is clean.
2. Send: "clean up this worktree, I'm done."

**Expected:**

- Claude runs `git worktree remove .vibing/worktrees/fix-auth-session-bug` (no `--force`).
- `git worktree list --porcelain` no longer shows it, and the directory is gone from disk.
- If this was the chat's own `working_dir`, that frontmatter field is cleared (chat reverts to
  operating in the main repo root).

## 5. Finish a worktree — refused due to uncommitted changes

**Steps:**

1. Create a worktree per Scenario 2, then make an uncommitted change inside it (e.g. edit a
   file) without committing or stashing.
2. Send: "clean up this worktree."

**Expected:**

- `git worktree remove` fails because of the uncommitted change.
- Claude surfaces the exact git error to the user and does **not** retry with `--force`.
- The worktree and the uncommitted change are both still present after this exchange.

## 6. Attach/create with no `vibing-nvim` MCP connection

**Steps:**

1. Start a chat with the `vibing-nvim` MCP server unavailable (e.g. no running Neovim RPC
   server on the configured port).
2. Send: "split this into its own worktree."

**Expected:**

- Claude still creates the worktree on disk via `git worktree add`.
- Since `nvim_get_info` isn't available, Claude does not attempt to edit chat frontmatter it
  can't locate — it tells the user the worktree's path and that `working_dir` needs to be set
  by hand (or a new chat opened there).

## Manual verification checklist

- [ ] Scenario 1: listing works with zero and with one-or-more worktrees present
- [ ] Scenario 2: create updates the _same_ chat's frontmatter, no new buffer
- [ ] Scenario 3: attach works from a brand-new chat's first message
- [ ] Scenario 4: finish removes the worktree and clears `working_dir` when applicable
- [ ] Scenario 5: finish refuses (no `--force`) when there are uncommitted changes
- [ ] Scenario 6: MCP-unavailable fallback degrades gracefully instead of erroring
```

- [ ] **Step 2: Verify markdown lint passes**

Run: `npm run lint:md`
Expected: no errors reported for `docs/e2e-tests/08-worktree-integration.md`.

- [ ] **Step 3: Commit**

```bash
git add docs/e2e-tests/08-worktree-integration.md
git commit -m "docs: rewrite worktree E2E scenarios for the vibing-worktree skill"
```

---

### Task 9: Full verification sweep

**Files:** none modified — verification only.

**Interfaces:** none.

- [ ] **Step 1: Run the full Lua test suite**

Run: `npm run test:lua`
Expected: PASS, including all specs added in Tasks 1-3.

- [ ] **Step 2: Run the full mcp-server test suite**

Run: `cd mcp-server && npx vitest run`
Expected: PASS, including `chat-tools.test.ts` from Task 4.

- [ ] **Step 3: Run Lua syntax check**

Run: `npm run check`
Expected: no syntax errors.

- [ ] **Step 4: Run lint**

Run: `npm run lint`
Expected: no errors. If the mcp-server build step (`cd mcp-server && npm run build`) is part of
CI, run it too and confirm it succeeds with the tool/handler removals from Task 4.

- [ ] **Step 5: Run markdown lint across the whole repo**

Run: `npm run lint:md`
Expected: no errors, confirming Tasks 6-8's new/edited docs are clean alongside everything else.

- [ ] **Step 6: Grep for leftover references to the removed system**

Run: `grep -rn "vibing-workspace\|\.vibing/workspace\|nvim_chat_worktree\|handleChatWorktree" --include="*.lua" --include="*.ts" --include="*.md" --include="*.mjs" .`
Expected: no output. (The predecessor investigation doc
`docs/superpowers/specs/2026-07-10-worktree-native-redesign.md` and this plan/the design doc
itself are historical records and may still mention the old system by name — exclude
`docs/superpowers/` from this check if it shows up there, that's expected.)

- [ ] **Step 7: Commit (only if this step surfaced fixes)**

If Steps 1-6 required any follow-up fixes, commit them now with a message describing what the
sweep caught. If everything passed cleanly with no changes, there is nothing to commit for this
task.
