# Chat Context Recall/Search Skills Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two vibing.nvim-bundled Claude Code skills — `vibing-chat-recall` (re-reads this
conversation's own chat buffer to recover lost context) and `vibing-chat-search` (finds past chat
files by natural-language query) — backed by a small core change that exposes the sending chat
buffer's file path to the Claude CLI process.

**Architecture:** `send_message.lua` reads the sending chat buffer's absolute file path from its
`bufnr` and passes it through the existing `opts` table as `opts.chat_file_path`.
`cli_command_builder.lua` appends that path as one extra line on the existing
`--append-system-prompt` flag, using the exact same pattern already used for the worktree
directory convention line. Both skills are plain `SKILL.md` prompt documents dropped into
`skills/`, following the existing `skills/nvim-context/` and `skills/vibing-worktree/` format —
no new Lua module is needed for the skills themselves.

**Tech Stack:** Lua (Neovim plugin code), plenary.nvim (`busted`-style specs), Markdown
(`SKILL.md` with YAML frontmatter), ripgrep-backed `Grep` tool (skill 2, used at skill-execution
time, not implementation time).

## Global Constraints

- SKILL.md frontmatter contains only `name` and `description` fields, matching every existing
  skill in `skills/`.
- The core change touches the Claude CLI adapter path only
  (`lua/vibing/application/chat/send_message.lua`,
  `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`). The Codex adapter
  (`codex_cli.lua` / `codex_command_builder.lua`) is out of scope — it has no equivalent
  system-prompt mechanism and SKILL.md skills are a Claude Code-only concept.
  See `docs/superpowers/specs/2026-07-10-chat-context-skills-design.md`.
- The new system prompt line must be unconditionally safe to add to every request — chats that
  never invoke either skill must see no behavior change beyond one extra ignorable line in the
  system prompt (same guarantee as the existing worktree-convention line).
- vibing.nvim chat buffers are **not auto-saved**; `vibing-chat-recall` must read the live Neovim
  buffer via the `vibing-nvim` MCP server as its primary path, not the on-disk file.
- `vibing-chat-search` must search `.vibing/chat/` matching both `.md` and `.vibing` file
  extensions, and must match against both `## User` and `## Assistant` content, not just user
  messages.
- `vibing-chat-search` output is a plain list only (path, datetime, 1-2 line summary per match) —
  no "open with this command" suggestions, no narrowing to a single best match.
- Implementation happens on a feature branch (per user instruction), not directly on `main`.

---

### Task 1: Propagate the sending chat buffer's file path through `send_message.lua`

**Files:**

- Modify: `lua/vibing/application/chat/send_message.lua:106-118`
- Test: `tests/lua/application/chat/send_message_spec.lua` (new file)

**Interfaces:**

- Consumes: `Vibing.ChatCallbacks.get_bufnr(): number` (already exists, documented at
  `send_message.lua:27`)
- Produces: `opts.chat_file_path: string|nil` — the absolute path of the chat buffer that
  originated this request, added to the `Vibing.AdapterOpts` table built in `do_send`. Task 2
  reads this field.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/application/chat/send_message_spec.lua`:

```lua
local SendMessage = require("vibing.application.chat.send_message")

describe("send_message", function()
  describe("execute", function()
    it("propagates the sending chat buffer's file path as opts.chat_file_path", function()
      local buf = vim.api.nvim_create_buf(false, true)
      local file_path = vim.fn.tempname() .. ".md"
      vim.api.nvim_buf_set_name(buf, file_path)

      local callbacks = {
        get_bufnr = function()
          return buf
        end,
        get_session_id = function()
          return "test-session"
        end,
        parse_frontmatter = function()
          return {}
        end,
        extract_conversation = function()
          return {}
        end,
        update_filename_from_message = function(_) end,
        start_response = function() end,
        get_session_allow = function()
          return {}
        end,
        get_session_deny = function()
          return {}
        end,
        add_user_section = function() end,
      }

      local captured = {}
      local adapter = {
        supports = function(_, _feature)
          return false
        end,
        execute = function(_, prompt, opts)
          captured.opts = opts
          captured.prompt = prompt
          return { content = "ok" }
        end,
      }

      SendMessage.execute(adapter, callbacks, "hello", {})

      assert.is_not_nil(captured.opts)
      assert.equals(vim.api.nvim_buf_get_name(buf), captured.opts.chat_file_path)

      vim.api.nvim_buf_delete(buf, { force = true })
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/send_message_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`

Expected: FAIL — `captured.opts.chat_file_path` is `nil`, not the buffer's file path
(`assert.equals` fails because the field doesn't exist yet).

- [ ] **Step 3: Add `chat_file_path` to the `opts` table**

In `lua/vibing/application/chat/send_message.lua`, inside `do_send`, the `opts` table currently
reads (starting at line 106):

```lua
    local opts = {
      streaming = true,
      action_type = "chat",
      mode = frontmatter.mode,
      model = frontmatter.model,
      permissions_allow = frontmatter.permissions_allow,
      permissions_deny = frontmatter.permissions_deny,
      permissions_ask = frontmatter.permissions_ask,
      permissions_session_allow = session_allow,
      permissions_session_deny = session_deny,
      permission_mode = frontmatter.permission_mode,
      language = lang_code,
      cwd = session_cwd,
      on_tool_use = function(tool, file_path, _command)
```

Change it to add `chat_file_path` right after `cwd`:

```lua
    local opts = {
      streaming = true,
      action_type = "chat",
      mode = frontmatter.mode,
      model = frontmatter.model,
      permissions_allow = frontmatter.permissions_allow,
      permissions_deny = frontmatter.permissions_deny,
      permissions_ask = frontmatter.permissions_ask,
      permissions_session_allow = session_allow,
      permissions_session_deny = session_deny,
      permission_mode = frontmatter.permission_mode,
      language = lang_code,
      cwd = session_cwd,
      chat_file_path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or nil,
      on_tool_use = function(tool, file_path, _command)
```

(`bufnr` is the `M.execute`-level local captured by the `do_send` closure — the same value
`callbacks.get_bufnr()` returned at the top of `M.execute`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/send_message_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/application/chat/send_message.lua tests/lua/application/chat/send_message_spec.lua
git commit -m "feat: propagate sending chat buffer path to adapter opts"
```

---

### Task 2: Append the chat buffer path to the Claude CLI system prompt

**Files:**

- Modify: `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua:149-154`
- Test: `tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua`

**Interfaces:**

- Consumes: `opts.chat_file_path: string|nil` (produced by Task 1)
- Produces: one extra line in the `--append-system-prompt` value, of the exact form
  `Current vibing.nvim chat buffer file: <path>`. Both skills in Task 3 and Task 4 depend on this
  exact line format to locate the sending chat's file path.

- [ ] **Step 1: Write the failing tests**

In `tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua`, inside the existing
`describe("system prompt", function() ... end)` block (after the two existing `it` blocks, before
its closing `end)`), add:

```lua
    it("appends the current chat buffer file path when provided", function()
      local cmd = cli_command_builder.build("hello", { chat_file_path = "/tmp/chat-test.md" }, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      assert.is_not_nil(idx)
      local prompt_text = cmd[idx + 1]
      assert.is_true(
        prompt_text:find("Current vibing.nvim chat buffer file: /tmp/chat-test.md", 1, true) ~= nil
      )
    end)

    it("omits the chat buffer file line when chat_file_path is not provided", function()
      local cmd = cli_command_builder.build("hello", {}, nil, {}, nil)
      local idx = find_flag(cmd, "--append-system-prompt")
      local prompt_text = cmd[idx + 1]
      assert.is_nil(prompt_text:find("Current vibing.nvim chat buffer file:", 1, true))
    end)
```

- [ ] **Step 2: Run tests to verify the new one fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`

Expected: 3 pass (the two pre-existing tests, plus "omits..." which already holds), 1 FAIL
("appends the current chat buffer file path when provided" — the line isn't added yet).

- [ ] **Step 3: Add the system prompt line**

In `lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua`, the system prompt
construction currently reads (starting at line 149):

```lua
  -- System prompt additions (worktree convention + optional language instruction)
  local system_prompt_lines = {
    "When creating a git worktree for isolated work, place it under "
      .. worktree_constants.DIR
      .. "<branch-name>/ at the repository root.",
  }

  local language = resolve_language(opts, config)
```

Change it to insert the chat file path line right after the worktree line:

```lua
  -- System prompt additions (worktree convention + chat file path + optional language)
  local system_prompt_lines = {
    "When creating a git worktree for isolated work, place it under "
      .. worktree_constants.DIR
      .. "<branch-name>/ at the repository root.",
  }

  if opts.chat_file_path and opts.chat_file_path ~= "" then
    table.insert(system_prompt_lines, "Current vibing.nvim chat buffer file: " .. opts.chat_file_path)
  end

  local language = resolve_language(opts, config)
```

- [ ] **Step 4: Run tests to verify they all pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua { minimal_init = 'tests/minimal_init.lua' }"`

Expected: PASS (4/4)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/adapter/modules/cli_command_builder.lua tests/lua/infrastructure/adapter/modules/cli_command_builder_spec.lua
git commit -m "feat: append current chat buffer path to Claude CLI system prompt"
```

---

### Task 3: Add the `vibing-chat-recall` skill

**Files:**

- Create: `skills/vibing-chat-recall/SKILL.md`

**Interfaces:**

- Consumes: the `Current vibing.nvim chat buffer file: <path>` system prompt line produced by
  Task 2; `mcp__vibing-nvim__nvim_load_buffer(filepath)` and
  `mcp__vibing-nvim__nvim_get_buffer(bufnr)` (existing MCP tools, no changes needed).
- Produces: nothing consumed by other tasks — this is a leaf skill.

- [ ] **Step 1: Write the skill file**

Create `skills/vibing-chat-recall/SKILL.md`:

````markdown
---
name: vibing-chat-recall
description: Use when a vibing.nvim chat session's context feels lost or discontinuous — after a session reset, a dropped connection, or when Claude's own reasoning no longer matches what was discussed earlier in this conversation. Re-reads this conversation's own chat buffer (the file whose path is announced via the "Current vibing.nvim chat buffer file:" line in the system prompt) to silently restore context. Also invoke when the user explicitly asks to "remember", "recall", or "re-read the chat history" (in any language). Not for browsing other, unrelated past chat files — use vibing-chat-search for that.
---

# vibing-chat-recall

Restores this conversation's own context after it appears to have been lost (session reset,
dropped RPC connection, compaction) by re-reading the live vibing.nvim chat buffer this
conversation is running in.

## When this applies

- The user explicitly asks to "思い出して" / "recall" / "re-read the chat history".
- Claude notices its own responses no longer track what was discussed earlier in this same
  conversation — a sign the session was silently reset or compacted.
- Invoked directly via `/vibing-chat-recall`.

This skill only makes sense inside a vibing.nvim chat session. If the environment doesn't look
like one (see below), say so briefly and stop — don't guess at a file to read.

## Locating this conversation's own chat file

Every request sent through vibing.nvim's Claude CLI adapter carries one extra line appended to
the system prompt:

```text
Current vibing.nvim chat buffer file: /absolute/path/to/chat.md
```
````

Use that path — never rely on which Neovim window currently has focus, since the user may have
switched away, or another chat may be running concurrently.

If that line isn't present in the system prompt, this skill isn't running inside vibing.nvim (or
is running against an older vibing.nvim build that doesn't send it yet). Tell the user briefly
and stop.

## Reading the buffer

1. Call `mcp__vibing-nvim__nvim_load_buffer` with `filepath` set to the path from the system
   prompt. This loads the file into a Neovim buffer in the background (no window switch) and
   returns its `bufnr`, whether or not it was already open.
2. Call `mcp__vibing-nvim__nvim_get_buffer` with that `bufnr` to fetch the buffer's current
   content. This is the _live_ in-memory content, including edits that haven't been written to
   disk yet — vibing.nvim chat buffers are not auto-saved, so the on-disk file can lag behind
   what's actually been discussed.
3. If either MCP call fails (no RPC connection, Neovim not reachable), fall back to reading the
   same path from disk with the normal `Read` tool. This may miss the most recent unsaved
   exchange, but is better than nothing.

## Responding

Read through the recovered conversation to rebuild context internally. Reply with a short
one-line acknowledgment only (e.g. "会話履歴を読み直しました。" / "Context restored.") — do not
summarize the conversation or propose next steps unless the user asks for that separately.

````

- [ ] **Step 2: Lint the new file**

Run: `npx markdownlint skills/vibing-chat-recall/SKILL.md`

Expected: no output (no lint errors). If MD013 (line length) fires, rewrap the offending prose
line under 120 characters — frontmatter lines are exempt (matches the existing long single-line
`description` fields in `skills/vibing-worktree/SKILL.md` and `skills/nvim-context/SKILL.md`).

- [ ] **Step 3: Commit**

```bash
git add skills/vibing-chat-recall/SKILL.md
git commit -m "feat: add vibing-chat-recall skill"
````

---

### Task 4: Add the `vibing-chat-search` skill

**Files:**

- Create: `skills/vibing-chat-search/SKILL.md`

**Interfaces:**

- Consumes: nothing produced by Task 1-3 — operates purely on `.vibing/chat/` via the `Grep`,
  `Read`, and `Bash` (for `git rev-parse --show-toplevel`) tools already available to every skill.
- Produces: nothing consumed by other tasks — this is a leaf skill.

- [ ] **Step 1: Write the skill file**

Create `skills/vibing-chat-search/SKILL.md`:

````markdown
---
name: vibing-chat-search
description: Use when the user wants to find a past vibing.nvim conversation by topic — phrases like "前に〜について聞いたことあったっけ", "did we talk about X before", "find that chat where I asked about Y". Searches every chat file under .vibing/chat/ (both User and Assistant content) for a natural-language query, narrows candidates with grep, then reads and semantically judges the survivors before presenting matches. Not for recovering this conversation's own lost context — use vibing-chat-recall for that.
---

# vibing-chat-search

Finds past vibing.nvim chat files relevant to a natural-language query, by grepping
`.vibing/chat/` for keyword candidates and then reading the survivors to judge actual relevance.

## When this applies

- The user asks something like "前に〜について聞いたことあったっけ" / "did we discuss X before" /
  "find the chat where I asked about Y".
- Claude suspects a similar topic was covered in an earlier, different conversation.
- Invoked directly via `/vibing-chat-search`.

Not for re-reading _this_ conversation's own history after context loss — that's
`vibing-chat-recall`.

## Step 1: Locate the chat directory

Resolve `.vibing/chat/` relative to the git repository root:

```bash
git rev-parse --show-toplevel
```
````

Then check `<root>/.vibing/chat/` exists. If the repo has no `.vibing/chat/` directory (not a
git repo, or the directory is missing), fall back to `.vibing/chat/` relative to the current
working directory. If neither exists, tell the user no chat history was found and stop.

## Step 2: Build search keywords

From the user's natural-language query, extract 2-4 candidate keywords or short phrases,
including obvious synonyms/rephrasings — chat content is free-form Japanese or English prose,
not structured data, so a single literal substring rarely covers how the topic was actually
phrased.

Example: query "前にwebfetchのURL表示について話した?" → candidates: `webfetch`, `WebFetch`,
`URL表示`, `閲覧したurl`.

## Step 3: Narrow candidates with Grep

Search both User and Assistant content — don't restrict to `## User` sections only, since the
user's original phrasing may be vague while the topic keyword shows up clearly in Claude's own
reply.

Use the `Grep` tool with `path: ".vibing/chat"`, one call per keyword (or a regex alternation),
`output_mode: "files_with_matches"`. Union the results across all keywords into one candidate
list.

If the candidate list is larger than ~15 files, don't read them all — narrow further:

- Re-run with `output_mode: "count"` and keep only the files with the highest match counts, or
- Tighten the keyword list to more specific terms before re-searching.

## Step 4: Read candidates and judge relevance

Read each remaining candidate file (or just the matched region with `-C` context via `Grep`'s
content mode, for longer files) and judge whether it's actually about what the user is asking —
a keyword hit alone isn't enough; discard files where the match is incidental or off-topic.

## Step 5: Present results

For each file that survives judging, list:

- File path (relative to repo root)
- Date/time — prefer the `created_at` field from the file's YAML frontmatter; fall back to
  parsing the timestamp out of the filename (e.g. `chat-20260208-211227-...`) if frontmatter is
  missing
- A 1-2 line summary of the relevant part

Present this as a plain list. Don't pick a single "best" match, don't suggest a command to open
one, and don't summarize beyond the 1-2 lines per file — opening the file is left to the user.

If nothing survives Step 4, say plainly that nothing was found rather than forcing a weak match.

````

- [ ] **Step 2: Lint the new file**

Run: `npx markdownlint skills/vibing-chat-search/SKILL.md`

Expected: no output (no lint errors). If MD013 fires, rewrap the offending line under 120
characters.

- [ ] **Step 3: Commit**

```bash
git add skills/vibing-chat-search/SKILL.md
git commit -m "feat: add vibing-chat-search skill"
````

---

## Post-plan verification

After Task 4, run the full Lua suite once to confirm nothing else regressed:

```bash
npm run test:lua
npm run lint:md
npm run check
```

All three must pass before this branch is considered done.
