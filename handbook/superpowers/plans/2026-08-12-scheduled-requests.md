# Scheduled Requests on Usage Limit — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user park a written chat message and have it sent verbatim once a usage limit resets — explicitly via `:VibingSchedule`, or automatically when `<CR>` lands during a known-active limit.

**Architecture:** Reuse the existing pending-resume store and libuv timers. Entries gain a `kind` field (`auto_resume` | `scheduled`); a `scheduled` entry's payload is the chat buffer's own unsent `## User` section rather than a fixed prompt. A new project-level `.vibing/limit-state.json` records the last observed reset time so a limit can be detected before a request is even sent.

**Tech Stack:** Lua 5.1 (LuaJIT) / Neovim API, plenary.nvim busted-style specs, `vim.loop` timers, `vim.json`.

## Global Constraints

- Spec of record: `docs/superpowers/specs/2026-08-12-scheduled-requests-design.md`. Read it before starting.
- Worktree: `.vibing/worktrees/scheduled-requests`, branch `scheduled-requests`. All work happens there.
- Existing `pending-resume.json` files must keep working: a missing `kind` reads as `auto_resume`.
- Existing `auto_resume` behaviour must not change: `enabled` gate, `max_retries`, skip-when-unsent-text, `state` handling, 8-day ceiling.
- Comments in code: minimal, English, explaining _why_ not _what_ — match the density in `auto_resume.lua` and `pending_resume.lua`.
- Commit messages: English, Semantic Commit format. A `pre-commit` hook runs `prettier --check` on `**/*.{js,mjs,ts,json,md,yml,yaml}`. If it fails, run `pnpm exec prettier --write <file>` and re-commit. **Use `pnpm`, never `npm`/`npx`** — `npm` is blocked in this shell.
- Run Lua tests with: `pnpm run test:lua`. Run a single spec with:
  `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile <path>" -c qa`
- Do not add a `## Assistant`-side feature, UI, or config beyond what this plan lists.

---

## File Structure

**New**

| File                                                    | Responsibility                                                                                |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `lua/vibing/core/utils/when.lua`                        | Parse a user-supplied time spec (`30m`, `18:30`, …) into Unix seconds. Pure, no Neovim state. |
| `lua/vibing/infrastructure/storage/limit_state.lua`     | Persist/read the project's last observed usage-limit reset.                                   |
| `tests/lua/core/utils/when_spec.lua`                    | Unit tests for the parser.                                                                    |
| `tests/lua/infrastructure/storage/limit_state_spec.lua` | Unit tests for the store.                                                                     |
| `tests/e2e/scheduled_request_spec.lua`                  | End-to-end: park, fire, cancel.                                                               |

**Modified**

| File                                                                                                          | Change                                                                    |
| ------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `lua/vibing/config.lua`                                                                                       | `agent.scheduled_requests` defaults + type annotation.                    |
| `lua/vibing/infrastructure/storage/pending_resume.lua`                                                        | `kind` on the `Vibing.PendingResume` class annotation.                    |
| `lua/vibing/application/chat/auto_resume.lua`                                                                 | `kind` dispatch in `fire()`, `M.schedule_request()`, restore eligibility. |
| `lua/vibing/application/chat/send_message.lua`                                                                | Record/clear limit state; re-schedule a rejected message.                 |
| `lua/vibing/presentation/chat/buffer.lua`                                                                     | Pre-emptive scheduling branch in `send_message()`; `_pending_user_text`.  |
| `lua/vibing/init.lua`                                                                                         | `:VibingSchedule`; `kind` column in `:VibingPendingResumes`.              |
| `tests/lua/application/chat/auto_resume_spec.lua`                                                             | Tests for the new predicates.                                             |
| `.claude/rules/features.md`, `.claude/rules/commands-reference.md`, `docs/configuration.md`, `doc/vibing.txt` | Docs.                                                                     |

---

### Task 1: Time spec parser (`when.lua`)

**Files:**

- Create: `lua/vibing/core/utils/when.lua`
- Test: `tests/lua/core/utils/when_spec.lua`

**Interfaces:**

- Consumes: nothing.
- Produces: `require("vibing.core.utils.when").parse(spec: string, now: number|nil) -> number|nil, string|nil`
  Returns Unix seconds on success, or `nil, reason` on failure. `now` defaults to `os.time()` and exists so tests are not wall-clock dependent.

**Note:** the spec's §7 lists `30m / 2h / 1h30m / 18:30 / 2026-08-12T18:30`, but its Testing section uses `:VibingSchedule 1s`. Seconds are therefore supported too — an E2E test cannot wait a minute.

- [ ] **Step 1: Write the failing test**

Create `tests/lua/core/utils/when_spec.lua`:

```lua
describe("when.parse", function()
  local When = require("vibing.core.utils.when")

  -- 2026-08-12 10:00:00 local time. Fixed so HH:MM cases are not wall-clock dependent.
  local NOW = os.time({ year = 2026, month = 8, day = 12, hour = 10, min = 0, sec = 0 })

  it("parses a seconds offset", function()
    assert.equals(NOW + 1, When.parse("1s", NOW))
  end)

  it("parses a minutes offset", function()
    assert.equals(NOW + 30 * 60, When.parse("30m", NOW))
  end)

  it("parses an hours offset", function()
    assert.equals(NOW + 2 * 3600, When.parse("2h", NOW))
  end)

  it("parses a combined hours+minutes offset", function()
    assert.equals(NOW + 90 * 60, When.parse("1h30m", NOW))
  end)

  it("parses a clock time later today", function()
    assert.equals(os.time({ year = 2026, month = 8, day = 12, hour = 18, min = 30, sec = 0 }), When.parse("18:30", NOW))
  end)

  it("rolls a clock time that already passed to the next day", function()
    assert.equals(os.time({ year = 2026, month = 8, day = 13, hour = 9, min = 0, sec = 0 }), When.parse("09:00", NOW))
  end)

  it("parses an absolute date-time", function()
    local expected = os.time({ year = 2026, month = 8, day = 14, hour = 7, min = 5, sec = 0 })
    assert.equals(expected, When.parse("2026-08-14T07:05", NOW))
  end)

  it("accepts a space instead of T in an absolute date-time", function()
    local expected = os.time({ year = 2026, month = 8, day = 14, hour = 7, min = 5, sec = 0 })
    assert.equals(expected, When.parse("2026-08-14 07:05", NOW))
  end)

  it("rejects an unparseable spec with a reason", function()
    local at, reason = When.parse("tomorrow-ish", NOW)
    assert.is_nil(at)
    assert.is_string(reason)
  end)

  it("rejects an out-of-range clock time", function()
    assert.is_nil(When.parse("25:00", NOW))
  end)

  it("rejects an empty spec", function()
    assert.is_nil(When.parse("", NOW))
  end)

  it("rejects a zero offset", function()
    -- A zero delay is almost certainly a typo, and firing instantly defeats the point.
    assert.is_nil(When.parse("0m", NOW))
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/core/utils/when_spec.lua" -c qa`
Expected: FAIL — `module 'vibing.core.utils.when' not found`.

- [ ] **Step 3: Write the implementation**

Create `lua/vibing/core/utils/when.lua`:

```lua
--- Parse a user-supplied time spec into a Unix timestamp
---
--- Used by `:VibingSchedule <when>`. Kept free of Neovim and clock state (`now` is injected) so
--- the rollover and range rules are testable without waiting on the wall clock.
---
--- @module vibing.core.utils.when

local M = {}

--- Relative offsets, longest pattern first: "1h30m" must not be consumed by the bare-hours rule.
local OFFSET_RULES = {
  { pattern = "^(%d+)h(%d+)m$", seconds = function(h, m) return h * 3600 + m * 60 end },
  { pattern = "^(%d+)h$", seconds = function(h) return h * 3600 end },
  { pattern = "^(%d+)m$", seconds = function(m) return m * 60 end },
  { pattern = "^(%d+)s$", seconds = function(s) return s end },
}

--- @param spec string
--- @param now number
--- @return number|nil offset_seconds
local function parse_offset(spec, now)
  for _, rule in ipairs(OFFSET_RULES) do
    local a, b = spec:match(rule.pattern)
    if a then
      local offset = rule.seconds(tonumber(a), tonumber(b))
      if offset > 0 then
        return now + offset
      end
      return nil
    end
  end
  return nil
end

--- @param hour number
--- @param min number
--- @return boolean
local function valid_clock(hour, min)
  return hour >= 0 and hour <= 23 and min >= 0 and min <= 59
end

--- Parse a time spec.
--- Accepts `90s` / `30m` / `2h` / `1h30m` (relative), `18:30` (next occurrence of that clock
--- time), and `2026-08-14T07:05` or `2026-08-14 07:05` (absolute).
--- @param spec string
--- @param now number|nil Defaults to os.time(); injected by tests
--- @return number|nil unix_seconds, string|nil reason
function M.parse(spec, now)
  now = now or os.time()

  if type(spec) ~= "string" then
    return nil, "expected a string"
  end
  spec = vim.trim(spec)
  if spec == "" then
    return nil, "empty time spec"
  end

  local offset_at = parse_offset(spec, now)
  if offset_at then
    return offset_at
  end

  local year, month, day, hour, min = spec:match("^(%d%d%d%d)-(%d%d)-(%d%d)[T ](%d%d):(%d%d)$")
  if year then
    hour, min = tonumber(hour), tonumber(min)
    if not valid_clock(hour, min) then
      return nil, "hour/minute out of range: " .. spec
    end
    return os.time({
      year = tonumber(year),
      month = tonumber(month),
      day = tonumber(day),
      hour = hour,
      min = min,
      sec = 0,
    })
  end

  hour, min = spec:match("^(%d%d?):(%d%d)$")
  if hour then
    hour, min = tonumber(hour), tonumber(min)
    if not valid_clock(hour, min) then
      return nil, "hour/minute out of range: " .. spec
    end
    local today = os.date("*t", now)
    local at = os.time({ year = today.year, month = today.month, day = today.day, hour = hour, min = min, sec = 0 })
    if at <= now then
      -- The clock time already passed today; the user means the next one.
      at = at + 24 * 60 * 60
    end
    return at
  end

  return nil, string.format("could not parse '%s' (try 30m, 2h, 1h30m, 18:30 or 2026-08-14T07:05)", spec)
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/core/utils/when_spec.lua" -c qa`
Expected: PASS, 12 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/core/utils/when.lua tests/lua/core/utils/when_spec.lua
git commit -m "feat(schedule): parse user time specs for scheduled requests"
```

---

### Task 2: Project-level limit state store

**Files:**

- Create: `lua/vibing/infrastructure/storage/limit_state.lua`
- Test: `tests/lua/infrastructure/storage/limit_state_spec.lua`

**Interfaces:**

- Consumes: `Vibing.RateLimitInfo` from `lua/vibing/core/utils/rate_limit.lua` (fields used: `resets_at`, `limit_type`).
- Produces:
  - `LimitState.get_path(cwd: string|nil) -> string`
  - `LimitState.load(cwd: string|nil) -> Vibing.LimitState|nil`
  - `LimitState.record(info: Vibing.RateLimitInfo, cwd: string|nil) -> boolean` — no-op returning `false` when `info.resets_at` is absent
  - `LimitState.get_active(cwd: string|nil) -> Vibing.LimitState|nil` — the record only while `resets_at > os.time()`
  - `LimitState.clear(cwd: string|nil)`
  - `LimitState.clear_cache()`
  - `--- @class Vibing.LimitState` with `resets_at: number`, `limit_type: string|nil`, `observed_at: number`

- [ ] **Step 1: Write the failing test**

Create `tests/lua/infrastructure/storage/limit_state_spec.lua`:

```lua
describe("limit_state", function()
  local LimitState = require("vibing.infrastructure.storage.limit_state")

  local tmp_root

  before_each(function()
    tmp_root = vim.fn.tempname()
    vim.fn.mkdir(tmp_root, "p")
    LimitState.clear_cache()
  end)

  after_each(function()
    if tmp_root then
      vim.fn.delete(tmp_root, "rf")
    end
  end)

  it("returns nil when no store exists", function()
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("records a reset time and reads it back", function()
    local resets_at = os.time() + 3600
    assert.is_true(LimitState.record({ resets_at = resets_at, limit_type = "five_hour" }, tmp_root))

    local state = LimitState.load(tmp_root)
    assert.is_not_nil(state)
    assert.equals(resets_at, state.resets_at)
    assert.equals("five_hour", state.limit_type)
    assert.is_number(state.observed_at)
  end)

  it("ignores rate limit info that carries no reset time", function()
    -- The hook and error-text channels report a rejection without a timestamp; such a record
    -- cannot answer "is the limit still active", so storing it would be worse than nothing.
    assert.is_false(LimitState.record({ limit_type = "five_hour" }, tmp_root))
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("reports an active limit while the reset is in the future", function()
    LimitState.record({ resets_at = os.time() + 600 }, tmp_root)
    assert.is_not_nil(LimitState.get_active(tmp_root))
  end)

  it("reports no active limit once the reset has passed", function()
    LimitState.record({ resets_at = os.time() - 1 }, tmp_root)
    assert.is_nil(LimitState.get_active(tmp_root))
  end)

  it("clears the record", function()
    LimitState.record({ resets_at = os.time() + 600 }, tmp_root)
    LimitState.clear(tmp_root)
    assert.is_nil(LimitState.load(tmp_root))
    assert.is_nil(LimitState.get_active(tmp_root))
  end)

  it("clearing a store that does not exist is a no-op", function()
    LimitState.clear(tmp_root)
    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("ignores a corrupt store instead of erroring", function()
    local path = LimitState.get_path(tmp_root)
    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
    vim.fn.writefile({ "{ not json" }, path)

    assert.is_nil(LimitState.load(tmp_root))
  end)

  it("stores under .vibing/limit-state.json", function()
    assert.is_truthy(LimitState.get_path(tmp_root):find("/%.vibing/limit%-state%.json$"))
  end)
end)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/storage/limit_state_spec.lua" -c qa`
Expected: FAIL — `module 'vibing.infrastructure.storage.limit_state' not found`.

- [ ] **Step 3: Write the implementation**

Create `lua/vibing/infrastructure/storage/limit_state.lua`:

```lua
--- The project's last observed usage-limit reset
---
--- `pending_resume.lua` answers "which chats are parked"; this answers the different question
--- "is the plan's limit currently exhausted", which a chat that has never hit the limit itself
--- still needs in order to schedule rather than send. One record per project, in
--- `<project root>/.vibing/limit-state.json`.
---
--- Only a record carrying a reset timestamp is stored: the StopFailure hook and the error-text
--- fallback confirm a rejection without saying when it lifts, and a record that cannot answer
--- "still active?" would strand every later request.
---
--- @module vibing.infrastructure.storage.limit_state

local Git = require("vibing.core.utils.git")

local M = {}

--- @class Vibing.LimitState
--- @field resets_at number Unix seconds when the limit lifts
--- @field limit_type string|nil e.g. "five_hour"
--- @field observed_at number Unix seconds when the limit was observed

--- Memoized `git rev-parse` results, keyed by the directory asked about — the same reason
--- pending_resume.lua caches: one send/receive cycle resolves the path several times.
--- @type table<string, string|false>
local root_cache = {}

--- @param dir string|nil
--- @return string|nil
local function git_root_cached(dir)
  local key = dir or "<cwd>"
  local cached = root_cache[key]
  if cached ~= nil then
    return cached or nil
  end
  local root = Git.get_root(dir)
  root_cache[key] = root or false
  return root
end

--- Drop memoized roots (test helper; also useful after a worktree is added or removed)
function M.clear_cache()
  root_cache = {}
end

--- @param cwd? string
--- @return string
function M.get_path(cwd)
  local root = git_root_cached(cwd) or cwd or vim.fn.getcwd()
  return root .. "/.vibing/limit-state.json"
end

--- Read the record, or nil when absent or unreadable.
--- @param cwd? string
--- @return Vibing.LimitState|nil
function M.load(cwd)
  local path = M.get_path(cwd)
  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return nil
  end

  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.resets_at) ~= "number" then
    return nil
  end

  return decoded
end

--- Record an observed limit. Ignored unless the payload carried a reset timestamp.
--- @param info Vibing.RateLimitInfo
--- @param cwd? string
--- @return boolean recorded
function M.record(info, cwd)
  if type(info) ~= "table" or type(info.resets_at) ~= "number" then
    return false
  end

  local path = M.get_path(cwd)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local json = vim.json.encode({
    resets_at = info.resets_at,
    limit_type = info.limit_type,
    observed_at = os.time(),
  })

  local ok, err = pcall(vim.fn.writefile, { json }, path)
  if not ok then
    vim.notify("[vibing] Failed to write limit-state.json: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

--- The record, but only while the limit is still in force.
--- @param cwd? string
--- @return Vibing.LimitState|nil
function M.get_active(cwd)
  local state = M.load(cwd)
  if state and state.resets_at > os.time() then
    return state
  end
  return nil
end

--- Forget the recorded limit. Called on any successful response — a request that got through
--- proves the limit is not in force, whatever the stored reset time claimed.
--- @param cwd? string
function M.clear(cwd)
  local path = M.get_path(cwd)
  if vim.fn.filereadable(path) == 1 then
    pcall(vim.fn.delete, path)
  end
end

return M
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/infrastructure/storage/limit_state_spec.lua" -c qa`
Expected: PASS, 9 successes.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/infrastructure/storage/limit_state.lua tests/lua/infrastructure/storage/limit_state_spec.lua
git commit -m "feat(schedule): record the project's last observed usage-limit reset"
```

---

### Task 3: Configuration defaults

**Files:**

- Modify: `lua/vibing/config.lua` (the `M.defaults.agent` table, currently ending at the
  `auto_resume_on_limit` block around line 200; and the `Vibing.Config` type annotations)
- Modify: `lua/vibing/infrastructure/storage/pending_resume.lua` (class annotation only)

**Interfaces:**

- Produces: `config.agent.scheduled_requests = { enabled: boolean, max_retries: number }`,
  defaults `true` and `3`.
- Produces: `Vibing.PendingResume.kind: "auto_resume"|"scheduled"|nil`.

- [ ] **Step 1: Add the defaults**

In `lua/vibing/config.lua`, immediately after the `auto_resume_on_limit = { ... }` block inside
`M.defaults.agent`, add:

```lua
    -- 使用量リミット中に送信しようとしたリクエストを、リセット後に送る予約に切り替える。
    -- リミット中のリクエストはどのみち失敗するため既定で有効。
    -- :VibingSchedule による明示的な予約はこのフラグに関係なく常に動く。
    scheduled_requests = {
      enabled = true,
      -- 予約したリクエストがまた弾かれたときに許可する再予約の回数。
      -- これがループの唯一の歯止めなので 0 未満にはしない。
      max_retries = 3,
    },
```

- [ ] **Step 2: Add the type annotation**

Find the `---@class Vibing.AgentConfig` (or equivalently named) annotation block in
`lua/vibing/config.lua` that documents `auto_resume_on_limit`, and add a sibling field in the same
style:

```lua
---@field scheduled_requests { enabled: boolean, max_retries: number }
```

If the agent config is annotated inline rather than as a named class, match whatever form
`auto_resume_on_limit` uses in that file — do not introduce a new annotation style.

- [ ] **Step 3: Annotate the new entry field**

In `lua/vibing/infrastructure/storage/pending_resume.lua`, extend the `Vibing.PendingResume`
class block (currently lines 14-22) with:

```lua
--- @field kind "auto_resume"|"scheduled"|nil What to send when the timer fires. "auto_resume"
---   (the default when absent, so pre-existing stores keep working) sends the configured
---   continuation prompt; "scheduled" sends the chat's own unsent `## User` body.
```

- [ ] **Step 4: Verify nothing broke**

Run: `pnpm run check && pnpm run test:lua`
Expected: syntax check passes; the full Lua suite passes with no new failures.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/config.lua lua/vibing/infrastructure/storage/pending_resume.lua
git commit -m "feat(schedule): add agent.scheduled_requests config and entry kind"
```

---

### Task 4: Arming a scheduled request (`AutoResume.schedule_request`)

**Files:**

- Modify: `lua/vibing/application/chat/auto_resume.lua`
- Test: `tests/lua/application/chat/auto_resume_spec.lua`

**Interfaces:**

- Consumes: `PendingResume.put/get/remove`, the module-local `schedule()`, `stop_timer()`,
  `compute_delay()` already in `auto_resume.lua`.
- Produces:
  - `AutoResume.schedule_request(chat_file_path: string, fire_at: number, opts: {limit_type: string|nil, retry_count: number|nil, max_retries: number|nil}|nil) -> boolean, string|nil`
  - `AutoResume._may_schedule(retry_count: number|nil, max_retries: number|nil) -> boolean`
  - `AutoResume._is_restorable(entry: Vibing.PendingResume, opts: table) -> boolean`

- [ ] **Step 1: Write the failing tests**

Append to `tests/lua/application/chat/auto_resume_spec.lua`, inside the top-level `describe`:

```lua
  describe("_may_schedule", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("allows scheduling when no budget is given (explicit :VibingSchedule)", function()
      assert.is_true(AutoResume._may_schedule(nil, nil))
    end)

    it("allows a re-schedule while the budget has room", function()
      assert.is_true(AutoResume._may_schedule(1, 3))
    end)

    it("refuses once the budget is spent", function()
      -- This is the only guard against fire -> rejected -> re-schedule looping forever.
      assert.is_false(AutoResume._may_schedule(3, 3))
    end)

    it("treats a missing retry_count as zero", function()
      assert.is_true(AutoResume._may_schedule(nil, 3))
    end)
  end)

  describe("_is_restorable", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("re-arms a scheduled entry even when auto-resume is disabled", function()
      -- The user asked for this one by hand; the opt-in flag governs unattended resumes only.
      local entry = { chat_file_path = "/a.md", kind = "scheduled", state = "waiting" }
      assert.is_true(AutoResume._is_restorable(entry, { enabled = false }))
    end)

    it("does not re-arm an auto_resume entry when the feature is disabled", function()
      local entry = { chat_file_path = "/a.md", kind = "auto_resume", state = "waiting" }
      assert.is_false(AutoResume._is_restorable(entry, { enabled = false }))
    end)

    it("re-arms an auto_resume entry when the feature is enabled", function()
      local entry = { chat_file_path = "/a.md", state = "waiting" }
      assert.is_true(AutoResume._is_restorable(entry, { enabled = true }))
    end)

    it("never re-arms an in_flight entry, whatever its kind", function()
      assert.is_false(
        AutoResume._is_restorable({ chat_file_path = "/a.md", kind = "scheduled", state = "in_flight" }, { enabled = true })
      )
    end)

    it("never re-arms an entry without a chat file path", function()
      assert.is_false(AutoResume._is_restorable({ kind = "scheduled", state = "waiting" }, { enabled = true }))
    end)
  end)

  describe("schedule_request", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("writes a scheduled entry armed for the requested time", function()
      local chat_path = tmp_root .. "/.vibing/chat/a.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")
      local fire_at = os.time() + 3600

      local ok = AutoResume.schedule_request(chat_path, fire_at, { limit_type = "five_hour" })
      assert.is_true(ok)

      local entry = PendingResume.get(chat_path)
      assert.is_not_nil(entry)
      assert.equals("scheduled", entry.kind)
      assert.equals(fire_at, entry.resets_at)
      assert.equals("five_hour", entry.limit_type)
      assert.equals("waiting", entry.state)

      AutoResume.cancel(chat_path)
    end)

    it("refuses when the re-schedule budget is spent", function()
      local chat_path = tmp_root .. "/.vibing/chat/b.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")

      local ok, reason = AutoResume.schedule_request(chat_path, os.time() + 60, { retry_count = 3, max_retries = 3 })
      assert.is_false(ok)
      assert.is_string(reason)
      assert.is_nil(PendingResume.get(chat_path))
    end)

    it("refuses a fire time far enough out to be implausible", function()
      -- Same 8-day ceiling auto-resume uses: a timer armed for months means a misread payload.
      local chat_path = tmp_root .. "/.vibing/chat/c.md"
      vim.fn.mkdir(vim.fn.fnamemodify(chat_path, ":h"), "p")

      local ok = AutoResume.schedule_request(chat_path, os.time() + 30 * 24 * 3600, {})
      assert.is_false(ok)
      assert.is_nil(PendingResume.get(chat_path))
    end)
  end)
```

Note: `schedule_request` resolves its store from the chat file's own directory (as
`PendingResume.put` does), which is why these tests place the chat file under `tmp_root`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/auto_resume_spec.lua" -c qa`
Expected: FAIL — `attempt to call field '_may_schedule' (a nil value)` and similar.

- [ ] **Step 3: Implement `_may_schedule` and `schedule_request`**

In `lua/vibing/application/chat/auto_resume.lua`, add the following **after the `M._compute_delay =
compute_delay` line (currently line 262)**. That position matters: `schedule_request` calls the
module-local `schedule()`, which is defined at lines 222-260, so it cannot go next to
`compute_delay`'s own definition higher up the file.

```lua
--- Whether another scheduled request may be armed.
--- A scheduled request that gets rejected re-arms itself (see send_message.lua), so this budget
--- is the only thing standing between a persistent limit and an unbounded retry loop. An
--- explicit :VibingSchedule passes no budget and is never refused.
--- @param retry_count number|nil
--- @param max_retries number|nil
--- @return boolean
local function may_schedule(retry_count, max_retries)
  if max_retries == nil then
    return true
  end
  return (retry_count or 0) < max_retries
end

M._may_schedule = may_schedule

--- Options passed to schedule() for scheduled entries.
--- grace_sec is zero because the caller already decided the exact moment: :VibingSchedule 30m
--- means 30 minutes, and a reset-derived time has the grace added by the caller.
local SCHEDULED_OPTS = { grace_sec = 0 }

--- Park a chat's unsent `## User` body and send it at `fire_at`.
--- The body is not copied anywhere: it stays in the chat buffer, and fire() reads it back. See
--- the design spec, "Where the body lives".
--- @param chat_file_path string
--- @param fire_at number Unix seconds
--- @param opts {limit_type: string|nil, retry_count: number|nil, max_retries: number|nil}|nil
--- @return boolean ok, string|nil reason
function M.schedule_request(chat_file_path, fire_at, opts)
  opts = opts or {}

  if not chat_file_path or chat_file_path == "" then
    return false, "no chat file path"
  end

  if not may_schedule(opts.retry_count, opts.max_retries) then
    return false, string.format("re-schedule budget of %d is spent", opts.max_retries)
  end

  local entry = {
    chat_file_path = chat_file_path,
    kind = "scheduled",
    resets_at = fire_at,
    limit_type = opts.limit_type,
    retry_count = opts.retry_count or 0,
    recorded_at = os.time(),
    state = "waiting",
  }

  local delay_sec, reason = compute_delay(entry, SCHEDULED_OPTS)
  if not delay_sec then
    return false, reason
  end

  PendingResume.put(entry)
  schedule(entry, SCHEDULED_OPTS)
  return true
end
```

Because `schedule()` calls `compute_delay()` itself and removes the entry when it returns nil,
checking first here means the store is never written for a rejected fire time.

- [ ] **Step 4: Make `schedule()`'s notification kind-aware**

`schedule()` currently notifies `"Usage limit hit - %s will resume in %s%s"`. Replace the
notification block at the end of `schedule()` with:

```lua
  local name = vim.fn.fnamemodify(path, ":t")
  local human = M.format_duration(math.floor(delay_ms / 1000))
  if (entry.kind or "auto_resume") == "scheduled" then
    vim.notify(
      string.format("[vibing] %s scheduled to send in %s (%s)", name, human, os.date("%H:%M", entry.resets_at)),
      vim.log.levels.INFO
    )
  else
    -- Say so when the delay is a guess. A bare "will resume in 5m" reads as a known reset time,
    -- but for a five-hour or weekly limit the fallback will almost certainly be rejected again.
    local qualifier = entry.resets_at and "" or " (no reset time reported; this is a fallback retry)"
    vim.notify(
      string.format("[vibing] Usage limit hit - %s will resume in %s%s", name, human, qualifier),
      vim.log.levels.INFO
    )
  end
```

- [ ] **Step 5: Implement `_is_restorable` and use it in `restore()`**

Replace the body of `M.restore()` with:

```lua
--- Whether a stored entry should be re-armed at startup.
--- An "in_flight" entry was already sent by a session whose outcome we never saw; re-sending it
--- would spend a request outside the retry budget. It is kept (not deleted) so its retry_count
--- still counts. A scheduled entry ignores the auto-resume opt-in: the user armed it by hand.
--- @param entry Vibing.PendingResume
--- @param opts table
--- @return boolean
local function is_restorable(entry, opts)
  if not entry.chat_file_path then
    return false
  end
  if (entry.state or "waiting") ~= "waiting" then
    return false
  end
  if (entry.kind or "auto_resume") == "scheduled" then
    return true
  end
  return opts.enabled == true
end

M._is_restorable = is_restorable

--- Re-arm timers for chats parked before Neovim was restarted.
--- Called once at startup; safe to call again (each chat's timer is replaced, not stacked).
function M.restore()
  local opts = get_options()

  for _, entry in pairs(PendingResume.load()) do
    if is_restorable(entry, opts) then
      schedule(entry, (entry.kind or "auto_resume") == "scheduled" and SCHEDULED_OPTS or opts)
    end
  end
end
```

Note the removed early `if not opts.enabled then return end`: scheduled entries must survive a
restart even when auto-resume is switched off. Place `is_restorable` above `M.restore()` in the
file.

- [ ] **Step 6: Call `restore()` unconditionally at startup**

In `lua/vibing/init.lua` around line 66, the `restore()` call is gated on
`M.config.agent.auto_resume_on_limit.enabled`. Remove that gate so scheduled requests are re-armed
regardless; `restore()` now applies the per-entry rule itself. Keep the surrounding
`vim.schedule`/`pcall` structure exactly as it is — only the `if` condition goes away.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/auto_resume_spec.lua" -c qa`
Expected: PASS — the pre-existing `restore eligibility` and `compute_delay` groups still pass, plus
12 new successes.

Then run the full suite: `pnpm run test:lua`
Expected: no new failures.

- [ ] **Step 8: Commit**

```bash
git add lua/vibing/application/chat/auto_resume.lua lua/vibing/init.lua tests/lua/application/chat/auto_resume_spec.lua
git commit -m "feat(schedule): arm scheduled requests through the pending-resume timer"
```

---

### Task 5: Firing a scheduled request

**Files:**

- Modify: `lua/vibing/application/chat/auto_resume.lua` (the module-local `fire()`, currently
  lines 137-215)
- Test: `tests/lua/application/chat/auto_resume_spec.lua`

**Interfaces:**

- Consumes: `AutoResume` internals from Task 4; `chat_buf:extract_user_message()`,
  `chat_buf:is_sending()`, `chat_buf:send_message()`, `chat_buf:get_buffer()` from
  `presentation/chat/buffer.lua`.
- Produces: `AutoResume._scheduled_decision(body: string|nil, is_sending: boolean) -> "send"|"drop", string|nil`

- [ ] **Step 1: Write the failing tests**

Append to `tests/lua/application/chat/auto_resume_spec.lua`, inside the top-level `describe`:

```lua
  describe("_scheduled_decision", function()
    local AutoResume = require("vibing.application.chat.auto_resume")

    it("sends when a body is waiting and the chat is idle", function()
      assert.equals("send", AutoResume._scheduled_decision("do the thing", false))
    end)

    it("drops when the chat is already sending", function()
      local action = AutoResume._scheduled_decision("do the thing", true)
      assert.equals("drop", action)
    end)

    it("drops when the body was deleted while the chat was parked", function()
      -- The body lives in the buffer, so the user can remove it. Sending an empty message, or
      -- the generic continuation prompt, would both be wrong.
      local action, reason = AutoResume._scheduled_decision(nil, false)
      assert.equals("drop", action)
      assert.is_string(reason)
    end)

    it("drops when the body is only whitespace", function()
      assert.equals("drop", AutoResume._scheduled_decision("   \n  ", false))
    end)
  end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/auto_resume_spec.lua" -c qa`
Expected: FAIL — `attempt to call field '_scheduled_decision' (a nil value)`.

- [ ] **Step 3: Implement the decision function and the scheduled fire path**

In `lua/vibing/application/chat/auto_resume.lua`, add above `fire()`:

```lua
--- Whether a due scheduled request should actually go out.
--- Split from fire_scheduled so the rules are testable without a live chat buffer.
--- @param body string|nil The chat's unsent `## User` body
--- @param is_sending boolean
--- @return "send"|"drop" action, string|nil reason
local function scheduled_decision(body, is_sending)
  if is_sending then
    return "drop", "the chat is already sending a request"
  end
  if not body or vim.trim(body) == "" then
    return "drop", "the scheduled message is empty"
  end
  return "send"
end

M._scheduled_decision = scheduled_decision

--- Send a chat's own parked `## User` body.
--- Unlike the auto_resume path this deliberately does NOT consult `enabled`: the user armed this
--- request explicitly (or accepted the swap at <CR> time), and a flag governing unattended token
--- spend should not silently discard it.
--- @param chat_file_path string
local function fire_scheduled(chat_file_path)
  local current = PendingResume.get(chat_file_path)
  if not current then
    return
  end

  local name = vim.fn.fnamemodify(chat_file_path, ":t")

  local chat_buf, err = resolve_chat_buffer(chat_file_path)
  if not chat_buf then
    PendingResume.remove(chat_file_path)
    vim.notify(string.format("[vibing] Scheduled request skipped for %s: %s", name, err), vim.log.levels.WARN)
    return
  end

  local action, reason = scheduled_decision(chat_buf:extract_user_message(), chat_buf:is_sending())
  if action == "drop" then
    PendingResume.remove(chat_file_path)
    vim.notify(string.format("[vibing] Scheduled request skipped for %s: %s", name, reason), vim.log.levels.WARN)
    return
  end

  -- Mark in flight before sending, for the same reason the auto_resume path does: a crash
  -- between here and the response must not let restore() send it a second time.
  current.state = "in_flight"
  PendingResume.put(current)

  -- Deliberately not ProgrammaticSender.send: it appends a *new* user section, and the body is
  -- already sitting in the unsent one this request exists to deliver.
  local ok, send_err = pcall(function()
    chat_buf:send_message()
  end)
  if not ok then
    PendingResume.remove(chat_file_path)
    vim.notify("[vibing] Scheduled request failed: " .. tostring(send_err), vim.log.levels.WARN)
    return
  end

  vim.notify(string.format("[vibing] Sent the request scheduled for %s", name), vim.log.levels.INFO)
end
```

Then, as the first statements of the existing `fire()` (after its `stop_timer(chat_file_path)`
call), dispatch:

```lua
  if (entry.kind or "auto_resume") == "scheduled" then
    return fire_scheduled(chat_file_path)
  end
```

Leave the rest of `fire()` untouched — the `auto_resume` path keeps every existing gate.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedFile tests/lua/application/chat/auto_resume_spec.lua" -c qa`
Expected: PASS, including the 4 new `_scheduled_decision` cases.

Run the full suite: `pnpm run test:lua`
Expected: no new failures.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/application/chat/auto_resume.lua tests/lua/application/chat/auto_resume_spec.lua
git commit -m "feat(schedule): send the chat's parked message when its timer fires"
```

---

### Task 6: Record and clear limit state; re-schedule a rejected message

**Files:**

- Modify: `lua/vibing/application/chat/send_message.lua` (`M.execute` call sites at lines 219 and
  228; `M._handle_response` at lines 252-294; the `Vibing.ChatCallbacks` annotation at lines 18-36)
- Modify: `lua/vibing/presentation/chat/buffer.lua` (callbacks table around lines 460-505;
  `ChatBuffer:add_user_section()` at lines 549-562; the `ChatBuffer` class annotation at lines 19-20)

**Interfaces:**

- Consumes: `LimitState.record/clear` (Task 2); `AutoResume.schedule_request` (Task 4).
- Produces:
  - `Vibing.ChatCallbacks.set_pending_user_text: fun(text: string)` — stores text that the next
    `add_user_section()` will pre-fill.
  - `ChatBuffer._pending_user_text: string|nil`
  - `M._handle_response(response, callbacks, adapter, config, mote_configs, modified_file_paths, message)`
    — one new trailing parameter.

**Why the pre-fill indirection:** `add_user_section()` is invoked from three different places in
`_handle_response` (lines 375, 415, 500), two of them inside `vim.schedule` or a mote callback.
Appending the rejected body directly would race with whichever path runs. `Renderer.addUserSection`
already accepts an `initial_message` argument (`renderer.lua:144`), so handing the text to the
buffer and letting it fill the section it creates is both simpler and race-free.

- [ ] **Step 1: Add the pre-fill hook to ChatBuffer**

In `lua/vibing/presentation/chat/buffer.lua`, extend the class annotation next to
`_pending_choices` / `_pending_approval` (lines 19-20):

```lua
---@field _pending_user_text string? 次のadd_user_section()で本文として差し込むテキスト
```

Change `ChatBuffer:add_user_section()` (line 557) to pass and consume it:

```lua
  Renderer.addUserSection(self.buf, self.win, self._pending_choices, self._pending_approval, self._pending_user_text)
  self._pending_choices = nil
  self._pending_user_text = nil
```

Add the setter method next to `ChatBuffer:insert_choices` (around line 580):

```lua
---次のユーザーセクションに差し込む本文を保存
---リミットで弾かれたメッセージを予約として書き戻すために使う
---@param text string
function ChatBuffer:set_pending_user_text(text)
  self._pending_user_text = text
end
```

And register it in the callbacks table (next to `add_user_section` at line 467):

```lua
    set_pending_user_text = function(text)
      return self:set_pending_user_text(text)
    end,
```

- [ ] **Step 2: Document the new callback**

In `lua/vibing/application/chat/send_message.lua`, add to the `Vibing.ChatCallbacks` annotation
(lines 18-36):

```lua
---@field set_pending_user_text fun(text: string) 次のユーザーセクションに差し込む本文を保存
```

- [ ] **Step 3: Thread `message` into `_handle_response`**

Change the signature at line 252 to:

```lua
function M._handle_response(response, callbacks, adapter, config, mote_configs, modified_file_paths, message)
```

and update both call sites (lines 219 and 228) to pass `message` as the seventh argument. `message`
is already in scope there — it is `M.execute`'s third parameter.

Update the doc comment above `_handle_response` to mention the new parameter, matching the file's
existing `---@param` style.

- [ ] **Step 4: Replace the rate-limit block**

Replace lines 286-294 (the `AutoResume` block) with:

```lua
  -- 使用量リミットで弾かれた場合の扱い:
  --   1. プロジェクト単位のリセット時刻を記録し、次の送信を事前に予約へ回せるようにする
  --   2. 弾かれた本文を未送信Userセクションとして書き戻し、リセット後に再送する予約を張る
  --   3. 予約に回せなかった場合だけ、従来の auto_resume（固定プロンプト）にフォールバックする
  -- リミット以外で正常終了したときはリトライ budget とリセット時刻の記録をクリアする。
  local AutoResume = require("vibing.application.chat.auto_resume")
  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local chat_file_path = (bufnr and vim.api.nvim_buf_is_valid(bufnr)) and vim.api.nvim_buf_get_name(bufnr) or nil
  local chat_dir = chat_file_path and vim.fn.fnamemodify(chat_file_path, ":h") or nil

  if response._rate_limit_info then
    pcall(LimitState.record, response._rate_limit_info, chat_dir)
    local rescheduled = false
    local ok, result = pcall(
      M._reschedule_rejected_message,
      callbacks,
      chat_file_path,
      response._rate_limit_info,
      message,
      config
    )
    if ok then
      rescheduled = result
    end
    if not rescheduled then
      pcall(AutoResume.on_rate_limited, chat_file_path, response._rate_limit_info)
    end
  elseif not response.error then
    pcall(AutoResume.on_success, chat_file_path)
    pcall(LimitState.clear, chat_dir)
  end
```

- [ ] **Step 5: Implement `_reschedule_rejected_message`**

Add this function to `lua/vibing/application/chat/send_message.lua`, immediately after
`_handle_response`:

```lua
---リミットで弾かれたメッセージを、リセット後に再送する予約に切り替える
---
---本文はバッファの未送信Userセクションが唯一の置き場所なので、ここではJSONに複製せず
---set_pending_user_textで次のセクションに差し込むよう予約するだけにする。
---セクション生成は_handle_response内の3経路（うち2つはvim.schedule/moteコールバック内）
---から行われるため、直接書き込むとどれが走るかで競合する。
---@param callbacks Vibing.ChatCallbacks
---@param chat_file_path string|nil
---@param info Vibing.RateLimitInfo
---@param message string|nil 弾かれたユーザーメッセージ
---@param config table
---@return boolean rescheduled 予約に切り替えられたか
function M._reschedule_rejected_message(callbacks, chat_file_path, info, message, config)
  local opts = (config.agent and config.agent.scheduled_requests) or {}
  if not opts.enabled then
    return false
  end
  if not chat_file_path or chat_file_path == "" or not message or vim.trim(message) == "" then
    return false
  end
  if not callbacks.set_pending_user_text then
    return false
  end

  -- リセット時刻が分からない場合は予約時刻を決められない。固定プロンプトを投げ直す
  -- auto_resume のフォールバック待ちにする方が、当てずっぽうの時刻で再送するより無害。
  if not info.resets_at then
    return false
  end

  local PendingResume = require("vibing.infrastructure.storage.pending_resume")
  local existing = PendingResume.get(chat_file_path)
  local retry_count = (existing and existing.retry_count or 0) + 1

  local AutoResume = require("vibing.application.chat.auto_resume")
  local grace = (config.agent and config.agent.auto_resume_on_limit and config.agent.auto_resume_on_limit.grace_sec)
    or 10

  local ok, reason = AutoResume.schedule_request(chat_file_path, info.resets_at + grace, {
    limit_type = info.limit_type,
    retry_count = retry_count,
    max_retries = opts.max_retries or 3,
  })
  if not ok then
    vim.notify(
      string.format(
        "[vibing] Not re-scheduling %s: %s",
        vim.fn.fnamemodify(chat_file_path, ":t"),
        tostring(reason)
      ),
      vim.log.levels.WARN
    )
    return false
  end

  callbacks.set_pending_user_text(message)
  return true
end
```

Returning `false` when it declines is what makes the existing `auto_resume` path the fallback, so
switching `scheduled_requests.enabled` off restores today's behaviour exactly.

- [ ] **Step 6: Verify**

Run: `pnpm run check && pnpm run test:lua`
Expected: syntax check passes; no new failures.

- [ ] **Step 7: Commit**

```bash
git add lua/vibing/application/chat/send_message.lua lua/vibing/presentation/chat/buffer.lua
git commit -m "feat(schedule): re-schedule a message the usage limit rejected"
```

---

### Task 7: Schedule instead of sending during a known limit

**Files:**

- Modify: `lua/vibing/presentation/chat/buffer.lua` (`ChatBuffer:send_message()`, lines 340-347)

**Interfaces:**

- Consumes: `LimitState.get_active` (Task 2), `AutoResume.schedule_request` (Task 4),
  `commands.is_command` (`application/chat/commands.lua:24`), `AutoResume.format_duration`.
- Produces: nothing new.

- [ ] **Step 1: Add the scheduling branch**

In `lua/vibing/presentation/chat/buffer.lua`, between the `local message = self:extract_user_message()`
guard (ends line 345) and `ConversationExtractor.commit_user_message(self.buf)` (line 347), insert:

```lua
  -- リミット中と分かっているならコミットせずに予約へ回す。commit_user_message を通さないので
  -- `## User <!-- unsent -->` がそのまま残り、それが発火時に送られる本文になる。
  if self:_try_schedule_instead_of_send(message) then
    self._is_sending = false
    return
  end
```

- [ ] **Step 2: Implement the helper**

Add this method to `lua/vibing/presentation/chat/buffer.lua`, immediately before
`ChatBuffer:send_message()`:

```lua
---リミット中の送信を予約に切り替える
---
---スラッシュコマンドと承認応答は対象外: 前者はローカル処理で完結し、後者は待っている
---セッションに届かないと意味がないため、どちらも遅らせる理由がない。
---@param message string
---@return boolean scheduled 予約に切り替えたか
function ChatBuffer:_try_schedule_instead_of_send(message)
  local config = require("vibing.config").get()
  local opts = (config.agent and config.agent.scheduled_requests) or {}
  if not opts.enabled then
    return false
  end

  local commands = require("vibing.application.chat.commands")
  if commands.is_command(message) then
    return false
  end

  local ApprovalParser = require("vibing.presentation.chat.modules.approval_parser")
  if self._pending_approval and ApprovalParser.is_approval_response(message) then
    return false
  end

  local chat_file_path = vim.api.nvim_buf_get_name(self.buf)
  if chat_file_path == "" then
    return false
  end

  local LimitState = require("vibing.infrastructure.storage.limit_state")
  local state = LimitState.get_active(vim.fn.fnamemodify(chat_file_path, ":h"))
  if not state then
    return false
  end

  local AutoResume = require("vibing.application.chat.auto_resume")
  local grace = (config.agent and config.agent.auto_resume_on_limit and config.agent.auto_resume_on_limit.grace_sec)
    or 10
  local fire_at = state.resets_at + grace

  local ok, reason = AutoResume.schedule_request(chat_file_path, fire_at, { limit_type = state.limit_type })
  if not ok then
    vim.notify("[vibing] Could not schedule this request: " .. tostring(reason), vim.log.levels.WARN)
    return false
  end

  -- 予約本文はバッファにしか無いので、再起動をまたいでも残るよう保存しておく。
  vim.api.nvim_buf_call(self.buf, function()
    vim.cmd("silent! write")
  end)

  vim.notify(
    string.format(
      "[vibing] Usage limit active - scheduled for %s (in %s). To send now: :VibingCancelResume, then <CR>.",
      os.date("%H:%M", fire_at),
      AutoResume.format_duration(math.max(fire_at - os.time(), 0))
    ),
    vim.log.levels.INFO
  )
  return true
end
```

Returning `false` on every failure path means a problem here degrades to "send normally", never to
"the message silently vanishes".

- [ ] **Step 3: Verify**

Run: `pnpm run check && pnpm run test:lua`
Expected: syntax check passes; no new failures.

- [ ] **Step 4: Commit**

```bash
git add lua/vibing/presentation/chat/buffer.lua
git commit -m "feat(schedule): park a message instead of sending it during a known limit"
```

---

### Task 8: `:VibingSchedule` and the `kind` column

**Files:**

- Modify: `lua/vibing/init.lua` (the `:VibingPendingResumes` command at lines 229-258; the
  `:VibingCancelResume` command at lines 260-292; add `:VibingSchedule` next to them)

**Interfaces:**

- Consumes: `When.parse` (Task 1), `LimitState.get_active` (Task 2),
  `AutoResume.schedule_request` (Task 4), `view.get_current()`, `notify`.
- Produces: the `:VibingSchedule [when]` user command.

- [ ] **Step 1: Register `:VibingSchedule`**

Add to `lua/vibing/init.lua`, immediately before the `:VibingPendingResumes` registration:

```lua
  vim.api.nvim_create_user_command("VibingSchedule", function(opts)
    local view = require("vibing.presentation.chat.view")
    local chat_buffer = view.get_current()
    if not chat_buffer then
      notify.warn("Not in a chat buffer")
      return
    end

    local bufnr = chat_buffer:get_buffer()
    local chat_file_path = vim.api.nvim_buf_get_name(bufnr)
    if chat_file_path == "" then
      notify.warn("Save this chat before scheduling a request")
      return
    end

    local message = chat_buffer:extract_user_message()
    if not message or vim.trim(message) == "" then
      notify.warn("Write a message under the '## User' header first")
      return
    end

    local AutoResume = require("vibing.application.chat.auto_resume")
    local agent = M.config.agent or {}
    local grace = (agent.auto_resume_on_limit and agent.auto_resume_on_limit.grace_sec) or 10

    local fire_at, reason
    if opts.args ~= "" then
      local When = require("vibing.core.utils.when")
      fire_at, reason = When.parse(opts.args)
      if not fire_at then
        notify.warn("Invalid time: " .. tostring(reason))
        return
      end
    else
      local LimitState = require("vibing.infrastructure.storage.limit_state")
      local state = LimitState.get_active(vim.fn.fnamemodify(chat_file_path, ":h"))
      if not state then
        notify.warn("No usage limit on record. Give a time, e.g. ':VibingSchedule 30m'")
        return
      end
      fire_at = state.resets_at + grace
    end

    local ok, err = AutoResume.schedule_request(chat_file_path, fire_at, {})
    if not ok then
      notify.warn("Could not schedule: " .. tostring(err))
      return
    end

    -- 予約本文はバッファにしか無いので、再起動をまたいでも残るよう保存しておく。
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! write")
    end)

    notify.info(
      string.format(
        "Scheduled for %s (in %s)",
        os.date("%Y-%m-%d %H:%M", fire_at),
        AutoResume.format_duration(math.max(fire_at - os.time(), 0))
      )
    )
  end, {
    nargs = "?",
    complete = function()
      return { "15m", "30m", "1h", "2h", "5h" }
    end,
    desc = "Schedule this chat's unsent message to be sent later",
  })
```

- [ ] **Step 2: Show `kind` in `:VibingPendingResumes`**

In the `:VibingPendingResumes` body, replace the `table.insert(lines, string.format(...))` call
(lines 246-256) with:

```lua
      local kind = (entry.kind or "auto_resume") == "scheduled" and "scheduled" or "auto-resume"
      table.insert(
        lines,
        string.format(
          "%s - %s [%s, %s, retries used: %d]",
          vim.fn.fnamemodify(entry.chat_file_path, ":t"),
          when,
          kind,
          entry.limit_type or "unknown limit",
          entry.retry_count or 0
        )
      )
```

Also change the "nothing to show" message from `"No chats are waiting on a usage limit reset"` to
`"No chats are waiting on a usage limit reset or a scheduled send"`, and the command's `desc` to
`"List chats waiting on a usage limit reset or a scheduled send"`.

- [ ] **Step 3: Update `:VibingCancelResume` wording**

Its behaviour is already correct (one entry per chat, either kind). Update only the user-facing
strings:

- `desc` → `"Cancel this chat's pending auto-resume or scheduled request (or 'all')"`
- the "no entry" branch → `"This chat has nothing scheduled"`
- the success branch → `"Cancelled the pending request for this chat"`

- [ ] **Step 4: Verify**

Run: `pnpm run check && pnpm run test:lua`
Expected: syntax check passes; no new failures.

Then load the plugin in a scratch Neovim and confirm the command exists:

```bash
nvim --headless -u tests/minimal_init.lua \
  -c 'lua require("vibing").setup({})' \
  -c 'lua assert(vim.fn.exists(":VibingSchedule") == 2, "VibingSchedule not registered")' \
  -c 'lua print("ok")' -c qa
```

Expected: prints `ok`.

- [ ] **Step 5: Commit**

```bash
git add lua/vibing/init.lua
git commit -m "feat(schedule): add :VibingSchedule and show entry kind in pending list"
```

---

### Task 9: E2E coverage

**Files:**

- Create: `tests/e2e/scheduled_request_spec.lua`

**Interfaces:**

- Consumes: everything from Tasks 1-8.
- Produces: nothing consumed by later tasks.

**Before writing:** invoke the `self-testing` skill (`.claude/skills/self-testing/SKILL.md`) and
read `tests/e2e/chat_basic_flow_spec.lua`. The helper (`lua/vibing/testing/e2e_helper.lua`) has
exactly four functions — `spawn_nvim_instance({headless, init_script, cwd})`, `send_keys`,
`wait_for_buffer_content(instance, pattern, timeout_ms)`, `cleanup_instance` — so anything else
goes through `vim.fn.rpcrequest(instance.job_id, "nvim_exec_lua", code, {})` directly, as below.

Each scenario runs against a throwaway git repo as the spawned instance's `cwd`, so the stores it
writes (`.vibing/limit-state.json`, `.vibing/pending-resume.json`) land in the temp dir and never
touch this repo's `.vibing/`. `init_script` must be absolute, because the spawned process's cwd is
no longer the plugin root.

- [ ] **Step 1: Write the E2E spec**

Create `tests/e2e/scheduled_request_spec.lua`:

```lua
-- E2E Tests for scheduled requests (usage-limit request parking)
local helper = require("vibing.testing.e2e_helper")

local TIMEOUTS = {
  CHAT_CREATION = 2000,
  BUFFER_READY = 5000,
  COMMAND = 1500,
  -- compute_delay clamps anything under 3s up to 3s, and the fired request is a real CLI call.
  SCHEDULED_SEND = 40000,
}

local PLUGIN_ROOT = vim.fn.getcwd()
local INIT_SCRIPT = PLUGIN_ROOT .. "/tests/minimal_init.lua"

---@param tmp string
---@return table<string, table>
local function read_pending(tmp)
  local path = tmp .. "/.vibing/pending-resume.json"
  if vim.fn.filereadable(path) == 0 then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return (ok and type(decoded) == "table") and decoded or {}
end

---@param tmp string
---@return table|nil entry, string|nil chat_path
local function first_pending(tmp)
  for path, entry in pairs(read_pending(tmp)) do
    return entry, path
  end
  return nil, nil
end

---A chat file has to exist on disk before it can be scheduled, so wait for the buffer to be one.
---@param instance table
local function open_chat(instance)
  helper.send_keys(instance, ":VibingChat<CR>")
  vim.wait(TIMEOUTS.CHAT_CREATION)
  assert.is_true(
    helper.wait_for_buffer_content(instance, "%.md", TIMEOUTS.BUFFER_READY),
    "Chat buffer should be created with a .md name"
  )
end

---@param instance table
---@param text string
local function type_message(instance, text)
  helper.send_keys(instance, "G")
  vim.wait(100)
  helper.send_keys(instance, "i")
  helper.send_keys(instance, text)
  helper.send_keys(instance, "<Esc>")
  vim.wait(200)
end

describe("E2E: Scheduled requests", function()
  local nvim_instance
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    -- A real repo so limit_state/pending_resume resolve the same root the plugin will.
    vim.fn.system({ "git", "-C", tmp, "init", "-q" })

    nvim_instance = helper.spawn_nvim_instance({
      headless = true,
      init_script = INIT_SCRIPT,
      cwd = tmp,
    })
  end)

  after_each(function()
    helper.cleanup_instance(nvim_instance)
    if tmp then
      vim.fn.delete(tmp, "rf")
    end
  end)

  it("parks a message instead of sending it while a limit is on record", function()
    -- Pretend the plan's limit was observed a moment ago and lifts in an hour.
    vim.fn.mkdir(tmp .. "/.vibing", "p")
    vim.fn.writefile({
      vim.json.encode({ resets_at = os.time() + 3600, limit_type = "five_hour", observed_at = os.time() }),
    }, tmp .. "/.vibing/limit-state.json")

    open_chat(nvim_instance)
    type_message(nvim_instance, "please do the thing")
    helper.send_keys(nvim_instance, "<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    -- The header keeps its unsent marker: commit_user_message was never reached.
    assert.is_true(
      helper.wait_for_buffer_content(nvim_instance, "## User <!%-%- unsent %-%->", TIMEOUTS.COMMAND),
      "The user section should still be unsent"
    )
    assert.is_true(
      helper.wait_for_buffer_content(nvim_instance, "please do the thing", TIMEOUTS.COMMAND),
      "The message body should still be in the buffer"
    )

    local entry = first_pending(tmp)
    assert.is_not_nil(entry, "A pending entry should have been written")
    assert.equals("scheduled", entry.kind)
    assert.equals("waiting", entry.state)
  end)

  it("sends the parked message when the scheduled time arrives", function()
    open_chat(nvim_instance)
    type_message(nvim_instance, 'Say "scheduled"')

    helper.send_keys(nvim_instance, ":VibingSchedule 1s<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    local entry = first_pending(tmp)
    assert.is_not_nil(entry, "The request should be armed")
    assert.equals("scheduled", entry.kind)

    -- When the request actually goes out, commit_user_message stamps the header with a
    -- timestamp and drops the unsent marker.
    assert.is_true(
      helper.wait_for_buffer_content(nvim_instance, "## .* Assistant", TIMEOUTS.SCHEDULED_SEND),
      "The scheduled request should have been sent"
    )
  end)

  it("cancels a scheduled request without losing the message", function()
    open_chat(nvim_instance)
    type_message(nvim_instance, "not yet please")

    helper.send_keys(nvim_instance, ":VibingSchedule 1h<CR>")
    vim.wait(TIMEOUTS.COMMAND)
    assert.is_not_nil(first_pending(tmp), "The request should be armed")

    helper.send_keys(nvim_instance, ":VibingCancelResume<CR>")
    vim.wait(TIMEOUTS.COMMAND)

    assert.is_nil(first_pending(tmp), "The entry should be gone")
    assert.is_true(
      helper.wait_for_buffer_content(nvim_instance, "not yet please", TIMEOUTS.COMMAND),
      "Cancelling must not delete what the user wrote"
    )
  end)
end)
```

Note the second scenario makes a real CLI call, as `chat_basic_flow_spec.lua` already does. Keep
the prompt trivial.

- [ ] **Step 2: Run the E2E suite**

Run: `pnpm run test:e2e`
Expected: PASS.

If it fails, apply the **3-try auto-fix rule** from `.claude/rules/self-testing.md`: analyse, make
one targeted fix, re-run — at most 3 attempts. If it still fails, stop and report the error, the
three fixes attempted, the suspected cause, and a suggested next step. Do not move on to Task 10
with E2E failing.

- [ ] **Step 3: Commit**

```bash
git add tests/e2e/scheduled_request_spec.lua
git commit -m "test(schedule): cover parking, firing and cancelling a scheduled request"
```

---

### Task 10: Documentation

**Files:**

- Modify: `.claude/rules/features.md` (the "Auto-Resume on Usage Limit" section)
- Modify: `.claude/rules/commands-reference.md` (the User Commands table)
- Modify: `docs/configuration.md` (the "Auto-Resume on Usage Limit" section)
- Modify: `doc/vibing.txt`

- [ ] **Step 1: `.claude/rules/features.md`**

Rename the section to `## Usage Limit: Auto-Resume and Scheduled Requests`, keep the existing
auto-resume paragraphs unchanged, and append:

```markdown
A pending entry has a `kind`. `auto_resume` (the default, and what a missing `kind` reads as)
sends the configured continuation prompt. `scheduled` sends the chat's own unsent `## User` body
instead — the body stays in the buffer rather than being copied into the store, so it remains
visible and editable while parked, and the chat file is saved when the request is armed.

Scheduled requests come from three places: `:VibingSchedule [when]`, a `<CR>` that lands while
`.vibing/limit-state.json` records a still-active limit, and a turn the limit actually rejected
(its message is written back into a fresh unsent section rather than discarded). The last two are
governed by `agent.scheduled_requests.enabled` (default `true`); `:VibingSchedule` is not, since
the user armed it by hand. `agent.scheduled_requests.max_retries` (default 3) bounds the
fire → rejected → re-schedule loop.

`.vibing/limit-state.json` holds one record per project — the last observed reset time — and is
what lets a chat that never hit the limit itself still schedule instead of send. It is written
only when the payload carried a reset timestamp, and cleared on any successful response, so a
limit that lifts early is forgotten as soon as one request gets through.

**Implementation:** `infrastructure/storage/limit_state.lua` (project limit record),
`core/utils/when.lua` (time spec parser), plus the `kind` dispatch in
`application/chat/auto_resume.lua`.
```

- [ ] **Step 2: `.claude/rules/commands-reference.md`**

Add a row to the User Commands table, immediately above `:VibingPendingResumes`:

```markdown
| `:VibingSchedule [when]` | Schedule this chat's unsent message (default: the recorded limit reset; or `30m`, `18:30`, …) |
```

Update the `:VibingPendingResumes` and `:VibingCancelResume` descriptions to mention scheduled
requests as well as auto-resumes.

- [ ] **Step 3: `docs/configuration.md`**

Under the existing "Auto-Resume on Usage Limit" section, add a `scheduled_requests` subsection
documenting both fields with their defaults, the accepted `when` formats
(`90s`, `30m`, `2h`, `1h30m`, `18:30`, `2026-08-14T07:05`, `2026-08-14 07:05`), the
next-day rollover rule for bare clock times, and the fact that a scheduled body lives in the chat
buffer (so deleting it before the timer fires cancels the send). Match the section's existing
prose style and heading depth.

- [ ] **Step 4: `doc/vibing.txt`**

Add `:VibingSchedule` to the command list in the same format as the surrounding entries, and add a
short paragraph to whichever section covers auto-resume. Keep the file's existing tag/column
conventions.

- [ ] **Step 5: Verify formatting**

Run: `pnpm run format:check && pnpm run lint:md`
Expected: both pass. If `format:check` complains, run `pnpm exec prettier --write <file>`.

- [ ] **Step 6: Commit**

```bash
git add .claude/rules/features.md .claude/rules/commands-reference.md docs/configuration.md doc/vibing.txt
git commit -m "docs: document scheduled requests and :VibingSchedule"
```

---

### Task 11: Full verification

- [ ] **Step 1: Run everything**

```bash
pnpm run check
pnpm run test:lua
pnpm run test:node
pnpm run test:e2e
pnpm run lint
pnpm run format:check
pnpm run lint:md
```

Expected: all pass. Record the actual output — do not report success without it.

- [ ] **Step 2: Manual smoke test**

In a real Neovim with the worktree on `runtimepath`:

1. `:VibingChat`, type a message, `:VibingSchedule 2m`. Confirm the notification, that the message
   stays unsent in the buffer, and that `:VibingPendingResumes` lists it as `scheduled`.
2. `:VibingCancelResume`. Confirm the entry disappears and the message is still there.
3. Re-schedule with `:VibingSchedule 1m`, restart Neovim, and confirm `:VibingPendingResumes` still
   lists it (restore path) and that it fires.

- [ ] **Step 3: Report**

Summarise: what was built, which files changed, the verification output, and anything left out.
