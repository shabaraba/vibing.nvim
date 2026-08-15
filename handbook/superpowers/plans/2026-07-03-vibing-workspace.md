# vibing-workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `:VibingChatWorktree` with a `.vibing/workspace/`-based workspace system (create/enter/done/list) managed entirely through chat slash commands, so worktree-backed work has trackable lifecycle state and each chat buffer binds to exactly one workspace.

**Architecture:** New `lua/vibing/infrastructure/workspace/` modules (`counter.lua`, `meta.lua`, `manager.lua`) own workspace directory/lifecycle logic, reusing `git worktree` mechanics ported from the old `infrastructure/worktree/manager.lua` (which is deleted). Four new slash-command handlers (`workspace_create`, `workspace_enter`, `workspace_done`, `workspace_list`) under `lua/vibing/application/chat/handlers/` are registered as `/vibing-workspace-*` commands. A `workspace_generator.lua` util (mirrors `title_generator.lua`) asks the AI to produce a localized description and an English kebab-case branch name from the chat conversation. A `WorkspaceChatScanner` (mirrors `ForkedChatScanner`) keeps `meta.yaml`'s `chat_files` list in sync when `:VibingSetFileTitle` renames a bound chat file.

**Tech Stack:** Lua (Neovim plugin), plenary.nvim (`busted`-style unit tests), existing `git worktree` CLI, existing `Frontmatter` YAML-subset parser reused for `meta.yaml`.

## Global Constraints

- Workspace directories live under `.vibing/workspace/{active,done}/<counter>-<branch>/`; the git worktree itself lives at `.../worktree/` inside that directory.
- The counter (`.vibing/workspace/.counter`) is global and monotonically increasing; numbers are never reused, even after a workspace moves to `done`.
- `workspace_id` format is `%04d-%s` (4-digit zero-padded counter + branch slug), e.g. `0001-fix-auth-session-bug`.
- One chat buffer may bind to at most one workspace, ever. `workspace_id` is written to the chat file's frontmatter once and `/vibing-workspace-create` / `/vibing-workspace-enter` both refuse to run again on an already-bound buffer.
- New slash commands are prefixed `vibing-workspace-` to avoid collisions with user-defined `.claude/commands/` custom commands: `/vibing-workspace-create`, `/vibing-workspace-enter`, `/vibing-workspace-done`, `/vibing-workspace-list`.
- `/vibing-workspace-done` never passes `--force` to `git worktree remove`; if git refuses due to uncommitted changes, that error is surfaced verbatim. Unmerged branches and incomplete `plan.md` TODOs (`- [ ]`) produce a confirmation prompt but do not hard-block.
- `:VibingChatWorktree`, `lua/vibing/infrastructure/worktree/manager.lua`, and the `.vibing/worktrees/<branch>/` chat-storage convention are removed (breaking change) — no automatic migration of pre-existing `.worktrees/` content.

---

### Task 1: Workspace counter

**Files:**

- Create: `lua/vibing/infrastructure/workspace/counter.lua`
- Test: `tests/lua/infrastructure/workspace/counter_spec.lua`

**Interfaces:**

- Consumes: `vibing.core.utils.git` — `Git.get_root(): string?`
- Produces: `Counter.next(): number?, string?` — returns the next 1-based global counter value (writes it back to `.vibing/workspace/.counter`) or `nil, error_message`. `Counter.get_counter_path(): string?` — absolute path to the counter file (used by tests to seed state).

- [ ] **Step 1: Write the failing test**

```lua
-- tests/lua/infrastructure/workspace/counter_spec.lua
local Counter = require("vibing.infrastructure.workspace.counter")

local function init_tmp_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.system(string.format("git -C %s init -q", vim.fn.shellescape(dir)))
  vim.fn.system(string.format("git -C %s config user.email test@example.com", vim.fn.shellescape(dir)))
  vim.fn.system(string.format("git -C %s config user.name test", vim.fn.shellescape(dir)))
  return dir
end

describe("vibing.infrastructure.workspace.counter", function()
  local repo
  local prev_cwd

  before_each(function()
    repo = init_tmp_git_repo()
    prev_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
    vim.fn.delete(repo, "rf")
  end)

  it("starts at 1 when no counter file exists", function()
    local n, err = Counter.next()
    assert.is_nil(err)
    assert.equals(1, n)
  end)

  it("increments on each call", function()
    local n1 = Counter.next()
    local n2 = Counter.next()
    local n3 = Counter.next()
    assert.equals(1, n1)
    assert.equals(2, n2)
    assert.equals(3, n3)
  end)

  it("persists the counter to .vibing/workspace/.counter", function()
    Counter.next()
    local path = Counter.get_counter_path()
    assert.equals(1, vim.fn.filereadable(path))
    assert.equals("1", vim.fn.readfile(path)[1])
  end)

  it("returns an error outside a git repository", function()
    vim.cmd("cd " .. vim.fn.fnameescape("/tmp"))
    -- /tmp itself might be inside a repo on some CI images; use a fresh non-repo dir instead
    local non_repo = vim.fn.tempname()
    vim.fn.mkdir(non_repo, "p")
    vim.cmd("cd " .. vim.fn.fnameescape(non_repo))

    local n, err = Counter.next()
    assert.is_nil(n)
    assert.is_not_nil(err)

    vim.fn.delete(non_repo, "rf")
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/counter_spec.lua"`
Expected: FAIL with "module 'vibing.infrastructure.workspace.counter' not found"

- [ ] **Step 3: Write minimal implementation**

```lua
-- lua/vibing/infrastructure/workspace/counter.lua
---@class Vibing.Infrastructure.Workspace.Counter
---.vibing/workspace/.counter を使ったグローバル連番採番
local M = {}

local Git = require("vibing.core.utils.git")

---@return string?
function M.get_counter_path()
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end
  return git_root .. "/.vibing/workspace/.counter"
end

---次の連番を採番し、カウンタファイルに永続化する
---@return number? next_number
---@return string? error
function M.next()
  local path = M.get_counter_path()
  if not path then
    return nil, "Not in a git repository"
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local current = 0
  if vim.fn.filereadable(path) == 1 then
    local lines = vim.fn.readfile(path)
    current = tonumber(lines[1]) or 0
  end

  local next_number = current + 1
  local result = vim.fn.writefile({ tostring(next_number) }, path)
  if result ~= 0 then
    return nil, "Failed to write counter file: " .. path
  end

  return next_number
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/counter_spec.lua"`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/workspace/counter.lua tests/lua/infrastructure/workspace/counter_spec.lua
git commit -m "feat: add workspace counter for global workspace numbering"
```

---

### Task 2: Workspace meta.yaml reader/writer

**Files:**

- Create: `lua/vibing/infrastructure/workspace/meta.lua`
- Test: `tests/lua/infrastructure/workspace/meta_spec.lua`

**Interfaces:**

- Consumes: `vibing.infrastructure.storage.frontmatter` — `Frontmatter.parse(content): table?, string?`, `Frontmatter.serialize(data, body): string`
- Produces:
  - `Meta.write(meta_path: string, data: table): boolean`
  - `Meta.read(meta_path: string): table?`
  - `Meta.add_chat_file(meta_path: string, chat_file: string): boolean, string?`
  - `Meta.replace_chat_file(meta_path: string, old_path: string, new_path: string): boolean, string?`

- [ ] **Step 1: Write the failing test**

```lua
-- tests/lua/infrastructure/workspace/meta_spec.lua
local Meta = require("vibing.infrastructure.workspace.meta")

describe("vibing.infrastructure.workspace.meta", function()
  local meta_path

  before_each(function()
    meta_path = vim.fn.tempname() .. "-meta.yaml"
  end)

  after_each(function()
    vim.fn.delete(meta_path)
  end)

  it("writes and reads back a meta.yaml", function()
    local ok = Meta.write(meta_path, {
      workspace_id = "0001-fix-auth-session-bug",
      branch = "fix-auth-session-bug",
      created_at = "2026-07-03T10:00:00",
      description = "auth session bug fix",
      chat_files = {},
    })
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.equals("0001-fix-auth-session-bug", data.workspace_id)
    assert.equals("fix-auth-session-bug", data.branch)
    assert.equals("auth session bug fix", data.description)
    assert.same({}, data.chat_files)
  end)

  it("returns nil when reading a missing file", function()
    assert.is_nil(Meta.read(meta_path))
  end)

  it("adds a chat_file to an empty list", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = {} })
    local ok = Meta.add_chat_file(meta_path, ".vibing/chat/a.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md" }, data.chat_files)
  end)

  it("does not duplicate an existing chat_file entry", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    Meta.add_chat_file(meta_path, ".vibing/chat/a.md")

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md" }, data.chat_files)
  end)

  it("appends a second chat_file entry", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    Meta.add_chat_file(meta_path, ".vibing/chat/b.md")

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/a.md", ".vibing/chat/b.md" }, data.chat_files)
  end)

  it("replaces a chat_file path", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md", ".vibing/chat/b.md" } })
    local ok = Meta.replace_chat_file(meta_path, ".vibing/chat/a.md", ".vibing/chat/renamed.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/renamed.md", ".vibing/chat/b.md" }, data.chat_files)
  end)

  it("returns false when replacing a path that is not in the list", function()
    Meta.write(meta_path, { workspace_id = "x", branch = "x", chat_files = { ".vibing/chat/a.md" } })
    local ok, err = Meta.replace_chat_file(meta_path, ".vibing/chat/missing.md", ".vibing/chat/renamed.md")
    assert.is_false(ok)
    assert.is_not_nil(err)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/meta_spec.lua"`
Expected: FAIL with "module 'vibing.infrastructure.workspace.meta' not found"

- [ ] **Step 3: Write minimal implementation**

```lua
-- lua/vibing/infrastructure/workspace/meta.lua
---@class Vibing.Infrastructure.Workspace.Meta
---meta.yaml の読み書き。既存の Frontmatter パーサをそのまま再利用する
---（--- ... --- で囲むことで、実装済みのYAMLサブセットパーサをそのまま使い回せるため）
local M = {}

local Frontmatter = require("vibing.infrastructure.storage.frontmatter")

---@param meta_path string
---@param data table
---@return boolean success
function M.write(meta_path, data)
  local content = Frontmatter.serialize(data, "")
  return vim.fn.writefile(vim.split(content, "\n"), meta_path) == 0
end

---@param meta_path string
---@return table? data
function M.read(meta_path)
  if vim.fn.filereadable(meta_path) == 0 then
    return nil
  end
  local content = table.concat(vim.fn.readfile(meta_path), "\n")
  local data = Frontmatter.parse(content)
  return data
end

---@param meta_path string
---@param chat_file string
---@return boolean success
---@return string? error
function M.add_chat_file(meta_path, chat_file)
  local data = M.read(meta_path)
  if not data then
    return false, "meta.yaml not found: " .. meta_path
  end

  data.chat_files = data.chat_files or {}
  for _, existing in ipairs(data.chat_files) do
    if existing == chat_file then
      return true
    end
  end

  table.insert(data.chat_files, chat_file)
  return M.write(meta_path, data)
end

---@param meta_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function M.replace_chat_file(meta_path, old_path, new_path)
  local data = M.read(meta_path)
  if not data or not data.chat_files then
    return false, "no chat_files in meta.yaml: " .. meta_path
  end

  local found = false
  for i, existing in ipairs(data.chat_files) do
    if existing == old_path then
      data.chat_files[i] = new_path
      found = true
    end
  end

  if not found then
    return false, "chat_file not found: " .. old_path
  end

  return M.write(meta_path, data)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/meta_spec.lua"`
Expected: PASS (7 tests)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/workspace/meta.lua tests/lua/infrastructure/workspace/meta_spec.lua
git commit -m "feat: add workspace meta.yaml reader/writer"
```

---

### Task 3: Workspace manager (create / list / get / done lifecycle)

**Files:**

- Create: `lua/vibing/infrastructure/workspace/manager.lua`
- Test: `tests/lua/infrastructure/workspace/manager_spec.lua`

**Interfaces:**

- Consumes:
  - `Vibing.Infrastructure.Workspace.Counter.next(): number?, string?` (Task 1)
  - `Vibing.Infrastructure.Workspace.Meta.write/read` (Task 2)
  - `vibing.core.utils.git` — `Git.get_root()`, `Git.get_relative_path(abs_path)`
- Produces:
  - `Manager.create(branch: string, description: string): table?, string?` — returns `{ id, dir, worktree_path, meta_path, plan_path }`
  - `Manager.list(status: "active"|"done"): table[]` — each entry `{ id, branch, description, dir }`
  - `Manager.get(workspace_id: string): table?` — `{ id, dir, status, meta_path, plan_path, worktree_path? }` (worktree_path only set when `status == "active"`)
  - `Manager.remove_worktree(workspace_id: string): boolean, string?` — runs `git worktree remove` (no `--force`)
  - `Manager.move_to_done(workspace_id: string): boolean, string?`
  - `Manager.is_branch_merged(branch: string): boolean`
  - `Manager.plan_has_incomplete_todos(plan_path: string): boolean`
  - `Manager.plan_template(description: string): string[]`

- [ ] **Step 1: Write the failing test**

```lua
-- tests/lua/infrastructure/workspace/manager_spec.lua
local Manager = require("vibing.infrastructure.workspace.manager")

local function init_tmp_git_repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local function run(cmd)
    vim.fn.system(string.format("git -C %s %s", vim.fn.shellescape(dir), cmd))
  end
  run("init -q")
  run("config user.email test@example.com")
  run("config user.name test")
  vim.fn.writefile({ "hello" }, dir .. "/README.md")
  run("add README.md")
  run("commit -q -m init")
  return dir
end

describe("vibing.infrastructure.workspace.manager", function()
  local repo
  local prev_cwd

  before_each(function()
    repo = init_tmp_git_repo()
    prev_cwd = vim.fn.getcwd()
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(prev_cwd))
    vim.fn.delete(repo, "rf")
  end)

  describe("create", function()
    it("creates workspace directory, meta.yaml, plan.md and a git worktree", function()
      local ws, err = Manager.create("fix-auth-session-bug", "auth session bug fix")
      assert.is_nil(err)
      assert.equals("0001-fix-auth-session-bug", ws.id)
      assert.equals(1, vim.fn.isdirectory(ws.dir))
      assert.equals(1, vim.fn.isdirectory(ws.worktree_path))
      assert.equals(1, vim.fn.filereadable(ws.meta_path))
      assert.equals(1, vim.fn.filereadable(ws.plan_path))

      local branches = vim.fn.systemlist("git branch --list fix-auth-session-bug")
      assert.equals(1, #branches)
    end)

    it("increments the workspace id on each call", function()
      local ws1 = Manager.create("first-task", "first")
      local ws2 = Manager.create("second-task", "second")
      assert.equals("0001-first-task", ws1.id)
      assert.equals("0002-second-task", ws2.id)
    end)

    it("rejects a branch name containing a path separator", function()
      local ws, err = Manager.create("feature/nested", "nested")
      assert.is_nil(ws)
      assert.is_not_nil(err)
    end)
  end)

  describe("list", function()
    it("lists only active workspaces by default content", function()
      Manager.create("task-a", "Task A")
      Manager.create("task-b", "Task B")

      local active = Manager.list("active")
      assert.equals(2, #active)

      local done = Manager.list("done")
      assert.equals(0, #done)
    end)
  end)

  describe("get", function()
    it("finds an active workspace by id", function()
      local ws = Manager.create("task-a", "Task A")
      local found = Manager.get(ws.id)
      assert.is_not_nil(found)
      assert.equals("active", found.status)
      assert.equals(ws.worktree_path, found.worktree_path)
    end)

    it("returns nil for unknown id", function()
      assert.is_nil(Manager.get("9999-does-not-exist"))
    end)
  end)

  describe("remove_worktree + move_to_done", function()
    it("removes the git worktree and moves the workspace dir to done", function()
      local ws = Manager.create("task-a", "Task A")

      local ok, err = Manager.remove_worktree(ws.id)
      assert.is_true(ok, err)
      assert.equals(0, vim.fn.isdirectory(ws.worktree_path))

      local moved, move_err = Manager.move_to_done(ws.id)
      assert.is_true(moved, move_err)

      assert.is_nil(Manager.get(ws.id).worktree_path)
      assert.equals("done", Manager.get(ws.id).status)
      assert.equals(0, #Manager.list("active"))
      assert.equals(1, #Manager.list("done"))
    end)

    it("fails to remove worktree when there are uncommitted changes", function()
      local ws = Manager.create("task-a", "Task A")
      vim.fn.writefile({ "dirty" }, ws.worktree_path .. "/dirty.txt")

      local ok, err = Manager.remove_worktree(ws.id)
      assert.is_false(ok)
      assert.is_not_nil(err)
      assert.equals(1, vim.fn.isdirectory(ws.worktree_path))
    end)
  end)

  describe("plan_has_incomplete_todos", function()
    it("returns true when plan.md has an unchecked item", function()
      local ws = Manager.create("task-a", "Task A")
      assert.is_true(Manager.plan_has_incomplete_todos(ws.plan_path))
    end)

    it("returns false once all items are checked", function()
      local ws = Manager.create("task-a", "Task A")
      vim.fn.writefile({ "# Task A", "", "## TODO", "", "- [x] done item", "", "## Notes" }, ws.plan_path)
      assert.is_false(Manager.plan_has_incomplete_todos(ws.plan_path))
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/manager_spec.lua"`
Expected: FAIL with "module 'vibing.infrastructure.workspace.manager' not found"

- [ ] **Step 3: Write minimal implementation**

```lua
-- lua/vibing/infrastructure/workspace/manager.lua
---@class Vibing.Infrastructure.Workspace.Manager
---workspaceのライフサイクル（作成・一覧・完了）を担当するモジュール
local M = {}

local notify = require("vibing.core.utils.notify")
local Git = require("vibing.core.utils.git")
local Counter = require("vibing.infrastructure.workspace.counter")
local Meta = require("vibing.infrastructure.workspace.meta")

---@return string?
local function get_workspace_base()
  local git_root = Git.get_root()
  if not git_root then
    return nil
  end
  return git_root .. "/.vibing/workspace"
end

---@param branch string
---@return boolean
local function is_valid_branch(branch)
  if not branch or branch == "" then
    return false
  end
  if branch:match("[/\\]") or branch:match("%.%.") then
    return false
  end
  return true
end

---@param branch string
---@param worktree_path string
---@return boolean success
---@return string? error
local function create_git_worktree(branch, worktree_path)
  local branches = vim.fn.systemlist("git branch --list " .. vim.fn.shellescape(branch))
  local branch_exists = branches and #branches > 0 and branches[1] ~= ""

  local cmd
  if branch_exists then
    cmd = string.format("git worktree add %s %s", vim.fn.shellescape(worktree_path), vim.fn.shellescape(branch))
  else
    cmd = string.format("git worktree add -b %s %s", vim.fn.shellescape(branch), vim.fn.shellescape(worktree_path))
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, result
  end
  return true, nil
end

---@param worktree_path string
local function setup_environment(worktree_path)
  local git_root = Git.get_root()
  if not git_root then
    return
  end

  local items_to_copy = {
    ".gitignore",
    ".nvmrc",
    ".node-version",
    "package.json",
    "package-lock.json",
    "yarn.lock",
    "pnpm-lock.yaml",
    "tsconfig.json",
    "tsconfig.*.json",
    ".eslintrc*",
    ".prettierrc*",
    "jest.config.*",
    "vitest.config.*",
    ".editorconfig",
  }

  for _, item in ipairs(items_to_copy) do
    local matches = vim.fn.glob(git_root .. "/" .. item, false, true)
    for _, source in ipairs(matches) do
      local relative_path = source:sub(#git_root + 2)
      local dest = worktree_path .. "/" .. relative_path
      local dest_dir = vim.fn.fnamemodify(dest, ":h")
      if vim.fn.isdirectory(dest_dir) == 0 then
        vim.fn.mkdir(dest_dir, "p")
      end
      vim.fn.system(string.format("cp -rp %s %s", vim.fn.shellescape(source), vim.fn.shellescape(dest)))
    end
  end
end

---@param worktree_path string
local function setup_node_modules(worktree_path)
  local git_root = Git.get_root()
  if not git_root then
    return
  end

  local main_node_modules = git_root .. "/node_modules"
  if vim.fn.isdirectory(main_node_modules) == 1 then
    vim.fn.system(string.format(
      "ln -sf %s %s",
      vim.fn.shellescape(main_node_modules),
      vim.fn.shellescape(worktree_path .. "/node_modules")
    ))
  end
end

---@param description string
---@return string[]
function M.plan_template(description)
  return {
    "# " .. description,
    "",
    "## TODO",
    "",
    "- [ ] ",
    "",
    "## Notes",
    "",
  }
end

---@param branch string
---@param description string
---@return table? workspace
---@return string? error
function M.create(branch, description)
  if not is_valid_branch(branch) then
    return nil, "Invalid branch name: " .. tostring(branch)
  end

  local base = get_workspace_base()
  if not base then
    return nil, "Not in a git repository"
  end

  local number, counter_err = Counter.next()
  if not number then
    return nil, counter_err
  end

  local id = string.format("%04d-%s", number, branch)
  local dir = base .. "/active/" .. id

  if vim.fn.isdirectory(dir) == 1 then
    return nil, "Workspace directory already exists: " .. dir
  end

  vim.fn.mkdir(dir, "p")

  local worktree_path = dir .. "/worktree"
  local ok, git_err = create_git_worktree(branch, worktree_path)
  if not ok then
    vim.fn.delete(dir, "rf")
    return nil, "Failed to create git worktree: " .. tostring(git_err)
  end

  setup_environment(worktree_path)
  setup_node_modules(worktree_path)

  local meta_path = dir .. "/meta.yaml"
  Meta.write(meta_path, {
    workspace_id = id,
    branch = branch,
    created_at = os.date("%Y-%m-%dT%H:%M:%S"),
    description = description,
    chat_files = {},
  })

  local plan_path = dir .. "/plan.md"
  vim.fn.writefile(M.plan_template(description), plan_path)

  return {
    id = id,
    dir = dir,
    worktree_path = worktree_path,
    meta_path = meta_path,
    plan_path = plan_path,
  }, nil
end

---@param status "active"|"done"
---@return table[]
function M.list(status)
  local base = get_workspace_base()
  if not base then
    return {}
  end

  local status_dir = base .. "/" .. status
  if vim.fn.isdirectory(status_dir) == 0 then
    return {}
  end

  local entries = {}
  local dirs = vim.fn.glob(status_dir .. "/*", false, true)
  table.sort(dirs)
  for _, dir in ipairs(dirs) do
    local meta_path = dir .. "/meta.yaml"
    local data = Meta.read(meta_path)
    if data then
      table.insert(entries, {
        id = data.workspace_id,
        branch = data.branch,
        description = data.description,
        dir = dir,
      })
    end
  end

  return entries
end

---@param workspace_id string
---@return table? workspace
function M.get(workspace_id)
  local base = get_workspace_base()
  if not base then
    return nil
  end

  for _, status in ipairs({ "active", "done" }) do
    local dir = base .. "/" .. status .. "/" .. workspace_id
    if vim.fn.isdirectory(dir) == 1 then
      local result = {
        id = workspace_id,
        dir = dir,
        status = status,
        meta_path = dir .. "/meta.yaml",
        plan_path = dir .. "/plan.md",
      }
      if status == "active" then
        result.worktree_path = dir .. "/worktree"
      end
      return result
    end
  end

  return nil
end

---@param workspace_id string
---@return boolean success
---@return string? error
function M.remove_worktree(workspace_id)
  local ws = M.get(workspace_id)
  if not ws or ws.status ~= "active" then
    return false, "Not an active workspace: " .. workspace_id
  end

  local cmd = string.format("git worktree remove %s", vim.fn.shellescape(ws.worktree_path))
  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return false, result
  end
  return true, nil
end

---@param workspace_id string
---@return boolean success
---@return string? error
function M.move_to_done(workspace_id)
  local ws = M.get(workspace_id)
  if not ws or ws.status ~= "active" then
    return false, "Not an active workspace: " .. workspace_id
  end

  local base = get_workspace_base()
  local done_dir = base .. "/done"
  vim.fn.mkdir(done_dir, "p")

  local target = done_dir .. "/" .. workspace_id
  local result = vim.fn.rename(ws.dir, target)
  if result ~= 0 then
    return false, "Failed to move workspace to done: " .. ws.dir
  end
  return true, nil
end

---@param branch string
---@return boolean
function M.is_branch_merged(branch)
  local merged = vim.fn.systemlist("git branch --merged")
  for _, line in ipairs(merged) do
    if vim.trim(line):gsub("^%*%s*", "") == branch then
      return true
    end
  end
  return false
end

---@param plan_path string
---@return boolean
function M.plan_has_incomplete_todos(plan_path)
  if vim.fn.filereadable(plan_path) == 0 then
    return false
  end
  local lines = vim.fn.readfile(plan_path)
  for _, line in ipairs(lines) do
    if line:match("^%s*%-%s*%[%s*%]") then
      return true
    end
  end
  return false
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/workspace/manager_spec.lua"`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/workspace/manager.lua tests/lua/infrastructure/workspace/manager_spec.lua
git commit -m "feat: add workspace manager for create/list/get/done lifecycle"
```

---

### Task 4: Remove `:VibingChatWorktree` and the old worktree manager (breaking change)

**Files:**

- Delete: `lua/vibing/infrastructure/worktree/manager.lua`
- Modify: `lua/vibing/init.lua:161-191` (remove `VibingChatWorktree` user command)
- Modify: `lua/vibing/presentation/chat/controller.lua:123-167` (remove `handle_open_worktree`)
- Modify: `lua/vibing/application/chat/use_case.lua:93-126` (remove `create_new_for_worktree`)
- Modify: `.claude/rules/commands-reference.md` (remove `:VibingChatWorktree` docs)
- Modify: `.claude/rules/architecture.md` (remove worktree-command references, point to workspace docs)

**Interfaces:**

- Consumes: none (pure removal)
- Produces: none (Task 3's `Manager` fully replaces this functionality for later tasks)

- [ ] **Step 1: Delete the old worktree manager module and its tests**

```bash
rm -f lua/vibing/infrastructure/worktree/manager.lua
```

(No `tests/` file referenced this module directly — confirmed by `grep -rl "infrastructure.worktree" tests/` returning nothing besides `lua/vibing/infrastructure/worktree/manager.lua` itself.)

- [ ] **Step 2: Remove `VibingChatWorktree` command registration**

In `lua/vibing/init.lua`, delete the entire block (originally lines 161-191):

```lua
  vim.api.nvim_create_user_command("VibingChatWorktree", function(opts)
    require("vibing.presentation.chat.controller").handle_open_worktree(opts.args)
  end, {
    nargs = "+",
    desc = "Open Vibing chat in git worktree with optional position ([right|left|top|bottom|back|current] <branch>)",
    complete = function(arg_lead, cmd_line, cursor_pos)
      local args = vim.split(cmd_line, "%s+")
      if #args == 2 then
        -- Complete position keywords
        local positions = { "right", "left", "top", "bottom", "back", "current" }
        local matches = {}
        for _, pos in ipairs(positions) do
          if pos:find("^" .. vim.pesc(arg_lead)) then
            table.insert(matches, pos)
          end
        end
        return matches
      elseif #args == 3 then
        -- Complete branch names
        local branches = vim.fn.systemlist("git branch --format='%(refname:short)'")
        local matches = {}
        for _, branch in ipairs(branches) do
          if branch:find("^" .. vim.pesc(arg_lead)) then
            table.insert(matches, branch)
          end
        end
        return matches
      end
      return {}
    end,
  })

```

Leave the surrounding `VibingChatFork` and `VibingSlashCommands` registrations untouched.

- [ ] **Step 3: Remove `handle_open_worktree` from the chat controller**

In `lua/vibing/presentation/chat/controller.lua`, delete the `M.handle_open_worktree` function (originally lines 123-167), leaving `return M` as the final line.

- [ ] **Step 4: Remove `create_new_for_worktree` from the chat use case**

In `lua/vibing/application/chat/use_case.lua`, delete the `M.create_new_for_worktree` function (originally lines 93-126, the block between the `create_new_in_directory` function and the `open_file` function's doc comment).

- [ ] **Step 5: Run the Lua syntax check and full test suite**

Run: `npm run check && npm run test:lua`
Expected: syntax check passes; no test references the deleted symbols (there were none — `create_new_for_worktree` and `handle_open_worktree` had no dedicated spec files), full suite green.

- [ ] **Step 6: Update `.claude/rules/commands-reference.md`**

Remove the `:VibingChatWorktree` row from the "User Commands" table and its "Command Semantics" paragraph (the `**\`:VibingChatWorktree\`\*\*` bullet block). These will be replaced by workspace slash-command docs in Task 10.

- [ ] **Step 7: Update `.claude/rules/architecture.md`**

In the "Git Worktree Integration" section, replace the `:VibingChatWorktree`-specific bullet list with a pointer:

```markdown
## Git Worktree Integration

Worktree-backed development now goes through the workspace system (`/vibing-workspace-create`,
`/vibing-workspace-enter`, `/vibing-workspace-done`, `/vibing-workspace-list`). See
`.claude/rules/commands-reference.md` for the full command reference. Workspace directories,
including the git worktree itself, live under `.vibing/workspace/{active,done}/<id>/`.
```

- [ ] **Step 8: Commit**

```bash
git add -A lua/vibing/init.lua lua/vibing/presentation/chat/controller.lua lua/vibing/application/chat/use_case.lua .claude/rules/commands-reference.md .claude/rules/architecture.md
git rm lua/vibing/infrastructure/worktree/manager.lua
git commit -m "refactor!: remove VibingChatWorktree in favor of vibing-workspace commands

BREAKING CHANGE: :VibingChatWorktree, the .worktrees/ convention, and
.vibing/worktrees/<branch>/ chat storage are removed. Use
/vibing-workspace-create instead."
```

---

### Task 5: Workspace description/branch generator

**Files:**

- Create: `lua/vibing/core/utils/workspace_generator.lua`
- Test: `tests/lua/core/utils/workspace_generator_spec.lua`

**Interfaces:**

- Consumes: `vibing.core.utils.language` — `get_language_code(language, action_type)`, `language_names[code]`; adapter contract `adapter:stream(prompt, opts, on_chunk, on_done)` (same shape used by `title_generator.lua`)
- Produces:
  - `WorkspaceGenerator.generate(raw_text: string, callback: fun(result: {description: string, branch: string}?, error: string?))`
  - `WorkspaceGenerator.sanitize_branch(text: string): string` (exported for reuse/testing)

- [ ] **Step 1: Write the failing test**

```lua
-- tests/lua/core/utils/workspace_generator_spec.lua
local WorkspaceGenerator = require("vibing.core.utils.workspace_generator")

describe("vibing.core.utils.workspace_generator", function()
  describe("sanitize_branch", function()
    it("lowercases and hyphenates", function()
      assert.equals("fix-auth-session-bug", WorkspaceGenerator.sanitize_branch("Fix Auth Session Bug"))
    end)

    it("strips non-alphanumeric characters", function()
      assert.equals("fix-auth-bug", WorkspaceGenerator.sanitize_branch("Fix: Auth Bug!!"))
    end)

    it("collapses repeated separators and trims edges", function()
      assert.equals("fix-bug", WorkspaceGenerator.sanitize_branch("  --Fix   Bug--  "))
    end)

    it("truncates to 50 characters", function()
      local long = string.rep("a", 80)
      local result = WorkspaceGenerator.sanitize_branch(long)
      assert.equals(50, #result)
    end)
  end)

  describe("generate", function()
    before_each(function()
      package.loaded["vibing"] = {
        get_adapter = function()
          return {
            stream = function(_, prompt, opts, on_chunk, on_done)
              on_chunk("DESCRIPTION: 認証セッションのバグ修正\nBRANCH: Fix Auth Session Bug\n")
              on_done({})
            end,
          }
        end,
        get_config = function()
          return { language = "ja", permissions = { mode = "acceptEdits", allow = {}, deny = {} } }
        end,
      }
    end)

    after_each(function()
      package.loaded["vibing"] = nil
    end)

    it("parses description and sanitized branch from the AI response", function()
      local result, err
      WorkspaceGenerator.generate("I need to fix a bug in the auth session handling", function(r, e)
        result, err = r, e
      end)

      assert.is_nil(err)
      assert.equals("認証セッションのバグ修正", result.description)
      assert.equals("fix-auth-session-bug", result.branch)
    end)

    it("returns an error for empty input", function()
      local result, err
      WorkspaceGenerator.generate("", function(r, e)
        result, err = r, e
      end)

      assert.is_nil(result)
      assert.is_not_nil(err)
    end)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/core/utils/workspace_generator_spec.lua"`
Expected: FAIL with "module 'vibing.core.utils.workspace_generator' not found"

- [ ] **Step 3: Write minimal implementation**

```lua
-- lua/vibing/core/utils/workspace_generator.lua
---@class Vibing.Utils.WorkspaceGenerator
---会話内容からworkspaceのdescription（設定言語）とbranch（英語kebab-case）を生成する
---:VibingSetFileTitleのtitle_generator.luaと同様のワンショットAI生成パターン
local M = {}

local language_utils = require("vibing.core.utils.language")

---@param text string
---@return string
function M.sanitize_branch(text)
  text = text:lower()
  text = text:gsub("[^%w%-]+", "-")
  text = text:gsub("%-+", "-")
  text = text:gsub("^%-+", ""):gsub("%-+$", "")
  if #text > 50 then
    text = text:sub(1, 50)
  end
  return text
end

---@param raw_text string ヒアリング済みの会話またはユーザー入力
---@param callback fun(result: {description: string, branch: string}?, error: string?)
function M.generate(raw_text, callback)
  if not raw_text or vim.trim(raw_text) == "" then
    callback(nil, "No description to generate workspace name from")
    return
  end

  local vibing = require("vibing")
  local adapter = vibing.get_adapter()
  local config = vibing.get_config()

  if not adapter then
    callback(nil, "No adapter configured")
    return
  end

  local lang_code = language_utils.get_language_code(config.language, "chat")
  local lang_name = (lang_code and language_utils.language_names[lang_code]) or "English"

  local prompt = raw_text
    .. "\n\n"
    .. "Based on the above, respond with exactly two lines in this format:\n"
    .. "DESCRIPTION: <a concise description of the task, in "
    .. lang_name
    .. ", max 40 characters>\n"
    .. "BRANCH: <a git branch name in English, kebab-case, lowercase, max 40 characters, no spaces>\n"
    .. "Respond with ONLY these two lines, nothing else."

  local collected = ""

  local opts = {
    permission_mode = config.permissions and config.permissions.mode or "acceptEdits",
    permissions_allow = config.permissions and config.permissions.allow or {},
    permissions_deny = config.permissions and config.permissions.deny or {},
  }

  adapter:stream(prompt, opts, function(chunk)
    collected = collected .. chunk
  end, function(response)
    if response.error then
      callback(nil, response.error)
      return
    end

    local text = collected ~= "" and collected or (response.content or "")
    local description = text:match("DESCRIPTION:%s*(.-)%s*\n") or text:match("DESCRIPTION:%s*(.-)%s*$")
    local branch = text:match("BRANCH:%s*(.-)%s*\n") or text:match("BRANCH:%s*(.-)%s*$")

    if not description or not branch or vim.trim(description) == "" or vim.trim(branch) == "" then
      callback(nil, "Failed to parse description/branch from AI response")
      return
    end

    callback({
      description = vim.trim(description),
      branch = M.sanitize_branch(branch),
    }, nil)
  end)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/core/utils/workspace_generator_spec.lua"`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/core/utils/workspace_generator.lua tests/lua/core/utils/workspace_generator_spec.lua
git commit -m "feat: add AI-driven workspace description/branch generator"
```

---

### Task 6: WorkspaceChatScanner (keep meta.yaml chat_files in sync on rename)

**Files:**

- Create: `lua/vibing/infrastructure/link/workspace_chat_scanner.lua`
- Test: `tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua`

**Interfaces:**

- Consumes: `Vibing.Infrastructure.Link.Scanner` base class (`lua/vibing/infrastructure/link/scanner.lua`); `Vibing.Infrastructure.Workspace.Meta` (Task 2); `vibing.core.utils.git` — `Git.get_relative_path`
- Produces: `WorkspaceChatScanner.new(): Vibing.Infrastructure.Link.WorkspaceChatScanner` implementing `find_target_files(base_dir)`, `contains_link(file_path, target_path)`, `update_link(file_path, old_path, new_path)` — used via `SyncManager.sync_links(old_path, new_path, { WorkspaceChatScanner.new() }, workspace_base_dir)` exactly like `ForkedChatScanner` is used today.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua
local WorkspaceChatScanner = require("vibing.infrastructure.link.workspace_chat_scanner")
local Meta = require("vibing.infrastructure.workspace.meta")

describe("vibing.infrastructure.link.workspace_chat_scanner", function()
  local base_dir
  local meta_path

  before_each(function()
    base_dir = vim.fn.tempname() .. "/workspace"
    vim.fn.mkdir(base_dir .. "/active/0001-fix-bug", "p")
    meta_path = base_dir .. "/active/0001-fix-bug/meta.yaml"
    Meta.write(meta_path, {
      workspace_id = "0001-fix-bug",
      branch = "fix-bug",
      chat_files = { ".vibing/chat/old-name.md" },
    })
  end)

  after_each(function()
    vim.fn.delete(base_dir, "rf")
  end)

  it("finds meta.yaml files under the workspace base dir", function()
    local scanner = WorkspaceChatScanner.new()
    local files = scanner:find_target_files(base_dir .. "/")
    assert.equals(1, #files)
    assert.is_truthy(files[1]:find("meta%.yaml$"))
  end)

  it("detects when a meta.yaml references the given chat file", function()
    local scanner = WorkspaceChatScanner.new()
    assert.is_true(scanner:contains_link(meta_path, ".vibing/chat/old-name.md"))
    assert.is_false(scanner:contains_link(meta_path, ".vibing/chat/other.md"))
  end)

  it("updates the chat_files entry in place", function()
    local scanner = WorkspaceChatScanner.new()
    local ok = scanner:update_link(meta_path, ".vibing/chat/old-name.md", ".vibing/chat/new-name.md")
    assert.is_true(ok)

    local data = Meta.read(meta_path)
    assert.same({ ".vibing/chat/new-name.md" }, data.chat_files)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua"`
Expected: FAIL with "module 'vibing.infrastructure.link.workspace_chat_scanner' not found"

- [ ] **Step 3: Write minimal implementation**

```lua
-- lua/vibing/infrastructure/link/workspace_chat_scanner.lua
---@class Vibing.Infrastructure.Link.WorkspaceChatScanner : Vibing.Infrastructure.Link.Scanner
---meta.yamlのchat_files配列を、チャットファイルリネーム時に同期するスキャナー
local WorkspaceChatScanner = {}
WorkspaceChatScanner.__index = WorkspaceChatScanner

local Scanner = require("vibing.infrastructure.link.scanner")
setmetatable(WorkspaceChatScanner, { __index = Scanner })

local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")

---@return Vibing.Infrastructure.Link.WorkspaceChatScanner
function WorkspaceChatScanner.new()
  return setmetatable({}, WorkspaceChatScanner)
end

---@param base_dir string
---@return string[]
function WorkspaceChatScanner:find_target_files(base_dir)
  if vim.fn.isdirectory(base_dir) == 0 then
    return {}
  end
  return vim.fn.glob(base_dir .. "**/meta.yaml", false, true)
end

---@param target_path string
---@return string
local function to_relative(target_path)
  return Git.to_display_path(target_path)
end

---@param file_path string
---@param target_path string
---@return boolean
function WorkspaceChatScanner:contains_link(file_path, target_path)
  local data = Meta.read(file_path)
  if not data or not data.chat_files then
    return false
  end

  local target_relative = to_relative(target_path)
  for _, chat_file in ipairs(data.chat_files) do
    if chat_file == target_relative or chat_file == target_path then
      return true
    end
  end
  return false
end

---@param file_path string
---@param old_path string
---@param new_path string
---@return boolean success
---@return string? error
function WorkspaceChatScanner:update_link(file_path, old_path, new_path)
  local old_relative = to_relative(old_path)
  local new_relative = to_relative(new_path)

  local ok, err = Meta.replace_chat_file(file_path, old_relative, new_relative)
  if ok then
    return true, nil
  end

  -- Fall back to matching the raw (non-relative) path, e.g. when Git root is unavailable
  return Meta.replace_chat_file(file_path, old_path, new_path)
end

return WorkspaceChatScanner
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua"`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/link/workspace_chat_scanner.lua tests/lua/infrastructure/link/workspace_chat_scanner_spec.lua
git commit -m "feat: sync workspace meta.yaml chat_files on chat file rename"
```

---

### Task 7: Wire `WorkspaceChatScanner` into `:VibingSetFileTitle`

**Files:**

- Modify: `lua/vibing/application/chat/handlers/set_file_title.lua:180-194`

**Interfaces:**

- Consumes: `WorkspaceChatScanner.new()` (Task 6), `SyncManager.sync_links` (existing), `Git.get_root()`

- [ ] **Step 1: Write the failing test**

Add to `tests/chat_init_spec.lua` is not appropriate (that file tests command registration, not rename behavior) — instead extend the existing manual/e2e coverage in Task 11. This task has no isolated unit test of its own because `set_file_title.lua`'s rename flow is already covered end-to-end by `tests/e2e/vibing_workspace_spec.lua` (Task 11, "renamed chat file updates meta.yaml"). Skip straight to implementation; Task 11's e2e test is the regression check for this wiring.

- [ ] **Step 2: Add the workspace sync call**

In `lua/vibing/application/chat/handlers/set_file_title.lua`, add the require near the other scanner require (top of file, after `local ForkedChatScanner = require(...)`):

```lua
local WorkspaceChatScanner = require("vibing.infrastructure.link.workspace_chat_scanner")
```

Then, inside the `if is_existing_file then ... end` block (originally lines 166-194), after the existing `fork_result` sync call and before computing `total_updated`, add:

```lua
      -- workspace meta.yaml内のchat_filesリンクを更新（.vibing/workspace/を検索）
      local git_root = require("vibing.core.utils.git").get_root()
      local workspace_result = { updated = 0, failed = 0 }
      if git_root then
        workspace_result = SyncManager.sync_links(
          old_file_path, new_file_path, { WorkspaceChatScanner.new() }, git_root .. "/.vibing/workspace/"
        )
      end
```

And update the totals line to include it:

```lua
      local total_updated = daily_result.updated + fork_result.updated + workspace_result.updated
      local total_failed = daily_result.failed + fork_result.failed + workspace_result.failed
```

- [ ] **Step 3: Run the Lua syntax check**

Run: `npm run check`
Expected: no syntax errors

- [ ] **Step 4: Commit**

```bash
git add lua/vibing/application/chat/handlers/set_file_title.lua
git commit -m "feat: sync workspace meta.yaml links on :VibingSetFileTitle rename"
```

---

### Task 8: `/vibing-workspace-create`

**Files:**

- Create: `lua/vibing/application/chat/handlers/workspace_create.lua`
- Modify: `lua/vibing/application/chat/init.lua` (register the command)

**Interfaces:**

- Consumes:
  - `Vibing.Infrastructure.Workspace.Manager.create(branch, description)` (Task 3)
  - `Vibing.Utils.WorkspaceGenerator.generate(raw_text, callback)` (Task 5)
  - `Vibing.Infrastructure.Workspace.Meta.add_chat_file(meta_path, chat_file)` (Task 2)
  - `ChatBuffer:extract_conversation()`, `ChatBuffer:update_frontmatter(key, value, update_timestamp)`, `ChatBuffer:parse_frontmatter()` (existing)
  - `vibing.core.utils.git` — `Git.get_relative_path`, `Git.to_display_path`
- Produces: registers slash command `vibing-workspace-create`. On success, binds the invoking `chat_buffer` to the new workspace (`workspace_id` frontmatter field + `working_dir` frontmatter field + `meta.yaml.chat_files` append) and appends a confirmation block to the chat buffer.

- [ ] **Step 1: Write the handler**

```lua
-- lua/vibing/application/chat/handlers/workspace_create.lua
local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")
local WorkspaceGenerator = require("vibing.core.utils.workspace_generator")
local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")

---@param chat_buffer Vibing.ChatBuffer
---@return string?
local function already_bound_workspace_id(chat_buffer)
  local frontmatter = chat_buffer:parse_frontmatter()
  local wid = frontmatter and frontmatter.workspace_id
  if type(wid) == "string" and wid ~= "" and wid ~= "~" then
    return wid
  end
  return nil
end

---@param chat_buffer Vibing.ChatBuffer
---@param lines string[]
local function append_to_buffer(chat_buffer, lines)
  local buf = chat_buffer.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, lines)
end

---@param chat_buffer Vibing.ChatBuffer
---@param generated {description: string, branch: string}
local function confirm_and_create(chat_buffer, generated)
  vim.ui.input({ prompt = "Workspace description: ", default = generated.description }, function(description)
    if not description or vim.trim(description) == "" then
      notify.warn("Workspace creation cancelled")
      return
    end

    vim.ui.input({ prompt = "Branch name: ", default = generated.branch }, function(branch)
      branch = branch and WorkspaceGenerator.sanitize_branch(branch) or ""
      if branch == "" then
        notify.warn("Workspace creation cancelled")
        return
      end

      local ws, err = Manager.create(branch, description)
      if not ws then
        notify.error("Failed to create workspace: " .. tostring(err), "Workspace")
        return
      end

      local working_dir = Git.get_relative_path(ws.worktree_path)
      chat_buffer:update_frontmatter("workspace_id", ws.id, false)
      if working_dir then
        chat_buffer:update_frontmatter("working_dir", working_dir, false)
      end

      if chat_buffer.file_path then
        Meta.add_chat_file(ws.meta_path, Git.to_display_path(chat_buffer.file_path))
      end

      append_to_buffer(chat_buffer, {
        "",
        string.format("Workspace `%s` created at `%s`.", ws.id, ws.dir),
        "",
      })

      notify.info(string.format("Workspace ready: %s", ws.id), "Workspace")
    end)
  end)
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return true
  end

  local bound = already_bound_workspace_id(chat_buffer)
  if bound then
    notify.error(
      string.format("This chat is already bound to workspace %s. Open a new chat to start another workspace.", bound),
      "Workspace"
    )
    return true
  end

  local raw_input
  if #args > 0 then
    raw_input = table.concat(args, " ")
  else
    local conversation = chat_buffer:extract_conversation()
    if #conversation == 0 then
      notify.warn(
        "Describe the task in chat first, or run /vibing-workspace-create <description>",
        "Workspace"
      )
      return true
    end
    local texts = {}
    for _, msg in ipairs(conversation) do
      table.insert(texts, string.format("[%s]: %s", msg.role, msg.content))
    end
    raw_input = table.concat(texts, "\n\n")
  end

  WorkspaceGenerator.generate(raw_input, function(generated, err)
    if err then
      notify.error("Failed to generate workspace name: " .. err, "Workspace")
      return
    end
    confirm_and_create(chat_buffer, generated)
  end)

  return true
end
```

- [ ] **Step 2: Register the command**

In `lua/vibing/application/chat/init.lua`, add after the `new-session` registration:

```lua
  commands.register({
    name = "vibing-workspace-create",
    handler = require("vibing.application.chat.handlers.workspace_create"),
    description = "Create a workspace (worktree + meta.yaml + plan.md): /vibing-workspace-create [description]",
  })
```

- [ ] **Step 3: Extend `tests/chat_init_spec.lua` to assert registration**

Read `tests/chat_init_spec.lua` first to match its existing assertion style, then add a case asserting `commands.commands["vibing-workspace-create"]` is registered (mirror the existing assertions for `"new-session"` in that same file).

- [ ] **Step 4: Run tests**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/chat_init_spec.lua"`
Expected: PASS, including the new `vibing-workspace-create` registration assertion

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/application/chat/handlers/workspace_create.lua lua/vibing/application/chat/init.lua tests/chat_init_spec.lua
git commit -m "feat: add /vibing-workspace-create slash command"
```

---

### Task 9: `/vibing-workspace-enter`

**Files:**

- Create: `lua/vibing/application/chat/handlers/workspace_enter.lua`
- Modify: `lua/vibing/application/chat/init.lua` (register the command)

**Interfaces:**

- Consumes: `Manager.list("active")`, `Manager.get(workspace_id)` (Task 3); `Meta.add_chat_file` (Task 2); `ChatBuffer:update_frontmatter`, `ChatBuffer:parse_frontmatter`
- Produces: registers slash command `vibing-workspace-enter`

- [ ] **Step 1: Write the handler**

```lua
-- lua/vibing/application/chat/handlers/workspace_enter.lua
local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")
local Meta = require("vibing.infrastructure.workspace.meta")
local Git = require("vibing.core.utils.git")

---@param chat_buffer Vibing.ChatBuffer
---@return string?
local function already_bound_workspace_id(chat_buffer)
  local frontmatter = chat_buffer:parse_frontmatter()
  local wid = frontmatter and frontmatter.workspace_id
  if type(wid) == "string" and wid ~= "" and wid ~= "~" then
    return wid
  end
  return nil
end

---@param chat_buffer Vibing.ChatBuffer
---@param workspace_id string
local function bind_to_workspace(chat_buffer, workspace_id)
  local ws = Manager.get(workspace_id)
  if not ws or ws.status ~= "active" then
    notify.error("No active workspace found: " .. workspace_id, "Workspace")
    return
  end

  local working_dir = Git.get_relative_path(ws.worktree_path)
  chat_buffer:update_frontmatter("workspace_id", ws.id, false)
  if working_dir then
    chat_buffer:update_frontmatter("working_dir", working_dir, false)
  end

  if chat_buffer.file_path then
    Meta.add_chat_file(ws.meta_path, Git.to_display_path(chat_buffer.file_path))
  end

  notify.info(string.format("Entered workspace: %s", ws.id), "Workspace")
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer then
    notify.error("No chat buffer")
    return true
  end

  local bound = already_bound_workspace_id(chat_buffer)
  if bound then
    notify.error(
      string.format("This chat is already bound to workspace %s. Open a new chat to enter another workspace.", bound),
      "Workspace"
    )
    return true
  end

  if args[1] and args[1] ~= "" then
    bind_to_workspace(chat_buffer, args[1])
    return true
  end

  local active = Manager.list("active")
  if #active == 0 then
    notify.warn("No active workspaces. Run /vibing-workspace-create first.", "Workspace")
    return true
  end

  vim.ui.select(active, {
    prompt = "Select workspace to enter:",
    format_item = function(item)
      return string.format("%s - %s (%s)", item.id, item.description or "", item.branch or "")
    end,
  }, function(choice)
    if choice then
      bind_to_workspace(chat_buffer, choice.id)
    end
  end)

  return true
end
```

- [ ] **Step 2: Register the command**

In `lua/vibing/application/chat/init.lua`, add:

```lua
  commands.register({
    name = "vibing-workspace-enter",
    handler = require("vibing.application.chat.handlers.workspace_enter"),
    description = "Bind this chat to an existing workspace: /vibing-workspace-enter [workspace_id]",
  })
```

- [ ] **Step 3: Extend `tests/chat_init_spec.lua`**

Add a case asserting `commands.commands["vibing-workspace-enter"]` is registered, matching Task 8's pattern.

- [ ] **Step 4: Run tests**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/chat_init_spec.lua"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/application/chat/handlers/workspace_enter.lua lua/vibing/application/chat/init.lua tests/chat_init_spec.lua
git commit -m "feat: add /vibing-workspace-enter slash command"
```

---

### Task 10: `/vibing-workspace-done`

**Files:**

- Create: `lua/vibing/application/chat/handlers/workspace_done.lua`
- Modify: `lua/vibing/application/chat/init.lua` (register the command)

**Interfaces:**

- Consumes: `Manager.get`, `Manager.plan_has_incomplete_todos`, `Manager.is_branch_merged`, `Manager.remove_worktree`, `Manager.move_to_done` (Task 3); `ChatBuffer:parse_frontmatter`
- Produces: registers slash command `vibing-workspace-done`

- [ ] **Step 1: Write the handler**

```lua
-- lua/vibing/application/chat/handlers/workspace_done.lua
local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")

---@param chat_buffer Vibing.ChatBuffer
---@return string?
local function current_workspace_id(chat_buffer)
  local frontmatter = chat_buffer:parse_frontmatter()
  local wid = frontmatter and frontmatter.workspace_id
  if type(wid) == "string" and wid ~= "" and wid ~= "~" then
    return wid
  end
  return nil
end

---@param workspace_id string
---@param ws table
local function finish(workspace_id, ws)
  local ok, err = Manager.remove_worktree(workspace_id)
  if not ok then
    notify.error("Failed to remove worktree (see git output below):\n" .. tostring(err), "Workspace")
    return
  end

  local moved, move_err = Manager.move_to_done(workspace_id)
  if not moved then
    notify.error("Worktree removed, but failed to move workspace to done: " .. tostring(move_err), "Workspace")
    return
  end

  notify.info(string.format("Workspace done: %s", workspace_id), "Workspace")
end

---@param workspace_id string
---@param ws table
local function confirm_and_finish(workspace_id, ws)
  local warnings = {}

  if Manager.plan_has_incomplete_todos(ws.plan_path) then
    table.insert(warnings, "plan.md still has unchecked TODO items.")
  end
  if not Manager.is_branch_merged(ws.branch or "") then
    table.insert(warnings, "The branch does not appear to be merged yet.")
  end

  if #warnings == 0 then
    finish(workspace_id, ws)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = table.concat(warnings, " ") .. " Finish this workspace anyway?",
  }, function(choice)
    if choice == "Yes" then
      finish(workspace_id, ws)
    else
      notify.info("Cancelled", "Workspace")
    end
  end)
end

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  local workspace_id = args[1]
  if not workspace_id or workspace_id == "" then
    if not chat_buffer then
      notify.error("No chat buffer and no workspace_id given")
      return true
    end
    workspace_id = current_workspace_id(chat_buffer)
  end

  if not workspace_id then
    notify.warn("This chat is not bound to a workspace. Usage: /vibing-workspace-done <workspace_id>", "Workspace")
    return true
  end

  local ws = Manager.get(workspace_id)
  if not ws or ws.status ~= "active" then
    notify.error("No active workspace found: " .. tostring(workspace_id), "Workspace")
    return true
  end

  -- branch is not part of Manager.get's return; read it from meta.yaml
  local Meta = require("vibing.infrastructure.workspace.meta")
  local data = Meta.read(ws.meta_path)
  ws.branch = data and data.branch

  confirm_and_finish(workspace_id, ws)
  return true
end
```

- [ ] **Step 2: Register the command**

In `lua/vibing/application/chat/init.lua`, add:

```lua
  commands.register({
    name = "vibing-workspace-done",
    handler = require("vibing.application.chat.handlers.workspace_done"),
    description = "Finish a workspace, removing its worktree: /vibing-workspace-done [workspace_id]",
  })
```

- [ ] **Step 3: Extend `tests/chat_init_spec.lua`**

Add a case asserting `commands.commands["vibing-workspace-done"]` is registered.

- [ ] **Step 4: Run tests**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/chat_init_spec.lua"`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/application/chat/handlers/workspace_done.lua lua/vibing/application/chat/init.lua tests/chat_init_spec.lua
git commit -m "feat: add /vibing-workspace-done slash command"
```

---

### Task 11: `/vibing-workspace-list` + docs update + E2E test

**Files:**

- Create: `lua/vibing/application/chat/handlers/workspace_list.lua`
- Modify: `lua/vibing/application/chat/init.lua` (register the command)
- Modify: `.claude/rules/commands-reference.md` (document the four new slash commands under "Slash Commands (in Chat)")
- Create: `tests/e2e/vibing_workspace_spec.lua`

**Interfaces:**

- Consumes: `Manager.list(status)` (Task 3)
- Produces: registers slash command `vibing-workspace-list`; appends a Markdown list to the chat buffer (same pattern as `handlers/help.lua`)

- [ ] **Step 1: Write the handler**

```lua
-- lua/vibing/application/chat/handlers/workspace_list.lua
local notify = require("vibing.core.utils.notify")
local Manager = require("vibing.infrastructure.workspace.manager")

---@param args string[]
---@param chat_buffer Vibing.ChatBuffer
---@return boolean
return function(args, chat_buffer)
  if not chat_buffer or not chat_buffer.buf or not vim.api.nvim_buf_is_valid(chat_buffer.buf) then
    notify.error("No valid chat buffer")
    return true
  end

  local status = (args[1] == "done") and "done" or "active"
  local workspaces = Manager.list(status)

  local lines = { "", string.format("# Workspaces (%s)", status), "" }
  if #workspaces == 0 then
    table.insert(lines, string.format("No %s workspaces.", status))
  else
    for _, ws in ipairs(workspaces) do
      table.insert(lines, string.format("- `%s` - %s (%s)", ws.id, ws.description or "", ws.branch or ""))
    end
  end
  table.insert(lines, "")

  local line_count = vim.api.nvim_buf_line_count(chat_buffer.buf)
  vim.api.nvim_buf_set_lines(chat_buffer.buf, line_count, line_count, false, lines)

  return true
end
```

- [ ] **Step 2: Register the command**

In `lua/vibing/application/chat/init.lua`, add:

```lua
  commands.register({
    name = "vibing-workspace-list",
    handler = require("vibing.application.chat.handlers.workspace_list"),
    description = "List workspaces: /vibing-workspace-list [done]",
  })
```

- [ ] **Step 3: Document the new commands**

In `.claude/rules/commands-reference.md`, add a row group under "Slash Commands (in Chat)":

```markdown
| `/vibing-workspace-create [description]` | Interactively create a workspace (worktree + meta.yaml + plan.md), bind this chat to it |
| `/vibing-workspace-enter [workspace_id]` | Bind this chat to an existing active workspace (fails if this chat is already bound) |
| `/vibing-workspace-done [workspace_id]` | Remove the workspace's worktree and move it from active to done |
| `/vibing-workspace-list [done]` | List active workspaces (or done, with the `done` argument) |
```

- [ ] **Step 4: Write the E2E test**

```lua
-- tests/e2e/vibing_workspace_spec.lua
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  COMMAND = 3000,
}

describe("E2E: vibing-workspace commands", function()
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

  it("lists no active workspaces in a fresh repository", function()
    helper.send_keys(nvim_instance, ":VibingChat<CR>")
    vim.wait(TIMEOUTS.CHAT_CREATION)

    local ok = helper.wait_for_buffer_content(nvim_instance, "%.md", TIMEOUTS.BUFFER_READY)
    assert.is_true(ok, "Chat buffer should be created")

    helper.send_keys(nvim_instance, "G")
    helper.send_keys(nvim_instance, "i")
    helper.send_keys(nvim_instance, "/vibing-workspace-list")
    helper.send_keys(nvim_instance, "<Esc>")
    helper.send_keys(nvim_instance, "<CR>")

    ok = helper.wait_for_buffer_content(nvim_instance, "No active workspaces", TIMEOUTS.COMMAND)
    assert.is_true(ok, "Workspace list should report no active workspaces")
  end)
end)
```

- [ ] **Step 5: Run all tests**

Run: `npm run test:lua && npm run test:e2e`
Expected: all suites PASS, including the two new specs from this task and Tasks 1-10

- [ ] **Step 6: Commit**

```bash
git add lua/vibing/application/chat/handlers/workspace_list.lua lua/vibing/application/chat/init.lua .claude/rules/commands-reference.md tests/e2e/vibing_workspace_spec.lua
git commit -m "feat: add /vibing-workspace-list slash command and workspace e2e coverage"
```

---

## Self-Review Notes

- **Spec coverage:** Directory layout (Task 3), counter (Task 1), meta.yaml schema (Task 2), create/enter/done/list flows (Tasks 8-11), breaking-change removal of `:VibingChatWorktree` (Task 4), AI description/branch generation (Task 5), chat-file rename sync (Tasks 6-7), and docs updates (Tasks 4, 11) are each covered by a task.
- **1 buffer = 1 workspace binding:** enforced identically in both `workspace_create.lua` and `workspace_enter.lua` via `already_bound_workspace_id`, checked against the `workspace_id` frontmatter field before any mutation.
- **No `--force`:** `Manager.remove_worktree` (Task 3) never appends `--force`; a dirty worktree surfaces git's own error text unchanged, verified by the "fails to remove worktree when there are uncommitted changes" test.
- **Type consistency check:** `Manager.create/list/get` all return workspace tables keyed by `id`/`dir`/`branch`/`description`/`meta_path`/`plan_path`/`worktree_path`, and every handler (Tasks 8-11) uses exactly those field names — no renamed fields between tasks.
