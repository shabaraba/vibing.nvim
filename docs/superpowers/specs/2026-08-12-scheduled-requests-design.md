# Scheduled Requests on Usage Limit — Design

**Date:** 2026-08-12
**Branch:** `scheduled-requests`

## Problem

`agent.auto_resume_on_limit` already parks a chat when a turn is rejected by a usage limit and
sends a continuation once the limit resets. It has two gaps:

1. **The user's own text is thrown away.** On rejection the CLI never accepted the message, so it
   is absent from the resumed session. Auto-resume sends the fixed prompt
   `Continue from where you left off.` (`auto_resume.lua:202`), and whatever the user actually
   wrote is lost.
2. **Nothing can be queued while the limit is already known to be active.** Auto-resume only
   arms on a rejection it observes. A user who knows the limit is exhausted cannot write a
   message — in this chat or a brand-new one — and have it sent when the window reopens. Worse,
   `fire()` deliberately _skips_ a chat that has unsent `## User` text (`auto_resume.lua:179`),
   which is exactly the state a queued message would be in.

## Solution

Introduce **scheduled requests**: a chat's unsent `## User` body is parked and sent verbatim at a
chosen time, reusing the existing pending-resume store and timer machinery.

### 1. Entry `kind`

`Vibing.PendingResume` gains a `kind` field:

| `kind`                  | Body sent                           | Armed by                                    |
| ----------------------- | ----------------------------------- | ------------------------------------------- |
| `auto_resume` (default) | `agent.auto_resume_on_limit.prompt` | Limit rejection, when `enabled`             |
| `scheduled` (new)       | The chat's unsent `## User` body    | `:VibingSchedule`, or `<CR>` during a limit |

A missing `kind` reads as `auto_resume`, so existing `pending-resume.json` files keep working.
One entry per chat (the store is keyed by `chat_file_path`), so a chat is either auto-resuming or
scheduled, never both. `scheduled` wins if both would apply — a body the user wrote beats a
generic continuation.

### 2. Where the body lives

**In the chat buffer, as the unsent `## User` section.** The store holds only the fire time and
bookkeeping. Rationale: the chat buffer is vibing.nvim's single source of truth, the section is
visible and editable after scheduling, and `fire()` only has to invert its existing
"unsent text present" branch instead of growing a second delivery path.

Scheduling saves the chat file so the body survives a Neovim restart. If the body is gone or
empty when the timer fires, the entry is dropped with a notification rather than sending
anything.

### 3. Project-level limit state (new `infrastructure/storage/limit_state.lua`)

`.vibing/limit-state.json`, one record per project:

```json
{ "resets_at": 1786000000, "limit_type": "five_hour", "observed_at": 1785980000 }
```

- **Written** wherever `response._rate_limit_info` is handled (`send_message.lua:290`), alongside
  the existing per-chat `on_rate_limited` call. Only written when `resets_at` is present —
  a record without a reset time cannot answer "is the limit active".
- **Cleared** on any successful response (same site as `AutoResume.on_success`). This is the
  safety valve for the pre-emptive path in §4: a limit that lifted early is forgotten the moment
  a request actually succeeds.
- **Read** via `get_active()`, which returns the record only while `resets_at > os.time()`.

Path resolution mirrors `pending_resume.lua` (git root of the given directory, `.vibing/` under
it), including the memoized `git rev-parse`.

### 4. `<CR>` during a known limit (`buffer.lua`, around line 340)

Between `extract_user_message()` and `commit_user_message()` — before the message is marked sent:

```text
message extracted
  ├─ slash command, or an approval response  → unchanged (never scheduled)
  ├─ LimitState.get_active() and agent.scheduled_requests.enabled
  │    → schedule it, leave the section uncommitted, reset _is_sending, return
  └─ otherwise                               → unchanged
```

`commands.is_command(message)` is a pure predicate, so it is safe to consult before the
scheduling branch. Approval responses are excluded because they must reach the session that is
waiting on them.

The notification names the time and the escape hatch, since the user may know better than the
recorded state:

> `[vibing] Usage limit active — scheduled for 18:32 (in 2h14m). To send now: :VibingCancelResume, then <CR>.`

### 5. Rejection after the fact (`send_message.lua`)

When a turn is rejected by a limit and `agent.scheduled_requests.enabled`, the rejected body is
re-appended as a fresh unsent `## User` section and scheduled. `M.execute` already has `message`
in scope at both `_handle_response` call sites (lines 219, 228), so it is threaded through as a
parameter rather than recovered from the buffer.

This keeps the buffer honest: the failed turn keeps its error text, and below it sits the message
that will be retried, visible and editable.

If `scheduled_requests.enabled` is false, the existing `auto_resume` behaviour applies unchanged.

### 6. Firing (`auto_resume.lua` `fire()`)

For `kind == "scheduled"`:

- **No `enabled` gate.** An explicit `:VibingSchedule` is a user instruction; a config flag that
  governs unattended token spend should not silence it.
- **The unsent-text check inverts:** the body is the payload. Empty body → drop the entry and
  notify.
- **Delivery is `chat_buf:send_message()` directly**, not `ProgrammaticSender.send`, which would
  append a _second_ user section on top of the one already holding the body.
- `retry_count` is carried over and checked against `agent.scheduled_requests.max_retries`
  (default 3). If a fired request is rejected again, §5 re-schedules it until that budget is
  spent, then warns and stops. This is the loop guard.

`kind == "auto_resume"` keeps every current gate (`enabled`, `max_retries`, skip-if-unsent-text).

The `state` field (`waiting` / `in_flight`) and the 8-day sanity ceiling apply to both kinds
unchanged.

### 7. `:VibingSchedule [when]`

- No argument → `LimitState.get_active().resets_at` plus `grace_sec`. If there is no active
  record, error with a hint to pass a time explicitly.
- `when` accepts `30m`, `2h`, `1h30m`, `18:30`, `2026-08-12T18:30` (new `core/utils/when.lua`,
  returning Unix seconds or `nil, reason`). Past `HH:MM` values roll to the next day.
- Errors if the buffer is not a chat, or its unsent `## User` section is empty.
- Saves the chat file, writes the entry, arms the timer, reports the fire time.

`:VibingPendingResumes` gains a `kind` column. `:VibingCancelResume` cancels either kind — one
entry per chat means it needs no new argument; only its description changes.

Creating a scheduled request in a _new_ buffer needs no special support: `:VibingChat`, type,
`:VibingSchedule`.

### 8. Configuration

```lua
agent = {
  auto_resume_on_limit = { --[[ unchanged ]] },
  scheduled_requests = {
    -- <CR> during a known-active limit schedules instead of sending.
    -- :VibingSchedule works regardless of this flag.
    enabled = true,
    -- Re-schedules allowed when a fired request is rejected again.
    max_retries = 3,
  },
}
```

`enabled` defaults to `true`: during an active limit a request can only fail, so converting it to
a scheduled one strictly improves the outcome, and the notification states how to override.

## Files

**New**

- `lua/vibing/infrastructure/storage/limit_state.lua`
- `lua/vibing/core/utils/when.lua`

**Changed**

- `lua/vibing/application/chat/auto_resume.lua` — `kind` dispatch, `M.schedule_request()`
- `lua/vibing/infrastructure/storage/pending_resume.lua` — `kind` on the class annotation
- `lua/vibing/application/chat/send_message.lua` — record/clear limit state, post-rejection scheduling
- `lua/vibing/presentation/chat/buffer.lua` — pre-emptive scheduling branch
- `lua/vibing/init.lua` — `:VibingSchedule`, `kind` in `:VibingPendingResumes`
- `lua/vibing/config.lua` — `agent.scheduled_requests`

**Docs**

- `.claude/rules/features.md`, `.claude/rules/commands-reference.md`, `docs/configuration.md`,
  `doc/vibing.txt`

## Testing

**Unit (`tests/lua/`)**

- `when.lua`: each accepted format, `HH:MM` rollover, rejected input
- `limit_state.lua`: write/read/clear, `get_active()` past vs. future, missing/corrupt file
- `auto_resume.fire()`: `scheduled` with a body sends it; empty body drops the entry;
  `auto_resume` behaviour unchanged; `max_retries` exhaustion stops re-scheduling
- `pending-resume.json` without `kind` loads as `auto_resume`

**E2E (`tests/e2e/`)**

- Seed `.vibing/limit-state.json` with a near-future `resets_at`, press `<CR>`, assert the
  section stays unsent and an entry is written
- `:VibingSchedule 1s` on a chat with a body, assert it fires
- `:VibingCancelResume` removes a scheduled entry

## Rejected alternatives

- **Storing the body in `pending-resume.json`.** Survives buffer loss, but the buffer and the
  store then disagree the moment the user edits the section, and it duplicates state the buffer
  already holds.
- **Post-rejection scheduling only (no pre-emptive branch).** Simpler and immune to a stale
  reset time, but burns a doomed request on every send during a limit — the exact experience
  this feature exists to remove.
- **Fixed-interval retry instead of a reset timestamp.** Needs no time bookkeeping, but spends
  requests polling a limit whose reset time the CLI already reports.

## Known gaps and follow-ups

Recorded during implementation review. None blocks the feature; each has a concrete failure
scenario and was judged shippable.

- **The store race is narrowed, not closed.** Two Neovim instances open on the same project both
  re-arm the same entry at startup. `fire_scheduled` bails when the entry is no longer `waiting`,
  but both can read `waiting` before either writes `in_flight`. Closing it needs an atomic
  claim in `pending_resume.lua`, not a read-modify-write.
- **`_session_corrupted` bypasses `discard_scheduled`.** `_handle_response` returns early on a
  Lua-side resume timeout, so an armed schedule survives a manual send that died that way. It
  only bites if the user then types a new message and abandons it — that text is sent unattended
  when the timer fires. The fix is hoisting `chat_file_path` above the early return.
- **The rejected-turn path writes the body back but never saves.** Restart before any save and
  `fire_scheduled` reads the disk copy: usually empty (dropped with a warning), but a file `:w`-ed
  during an earlier turn still carries that earlier `<!-- unsent -->` body and would re-send an
  already-answered message.
- **The `<CR>` interception carries no retry budget, and resets the count.** `buffer.lua`'s
  `_try_schedule_instead_of_send` calls `schedule_request` without `retry_count`/`max_retries`, so
  `may_schedule` waves it through and the entry's count goes back to 0. That is deliberate for a
  user pressing `<CR>` — the same reasoning as `:VibingSchedule` being unbudgeted — but it is also
  reachable _without_ a user: `fire_scheduled` sends through `chat_buf:send_message()`, which runs
  the same interception, so a limit still on record at fire time re-parks the request with a fresh
  budget. It can therefore re-park indefinitely, which the "loop guard" description of
  `max_retries` above does not cover. No request is spent while this happens, and one successful
  response clears `limit-state.json` and ends it — hence recorded rather than fixed.
- **`retry_count` is incremented at different points by the two callers.** The rejected-turn path
  passes the post-increment count to `may_schedule`, `on_rate_limited` passes the pre-increment
  one. Self-consistent, but it means `scheduled_requests.max_retries = 3` permits two
  re-schedules; the docs state the real number.
- **A scheduled body that is a slash command** executes locally, still reports "Sent…", and leaves
  an `in_flight` row that `restore()` will never re-arm.
- **Orphan `in_flight` rows** survive `:VibingCancel` and non-success outcomes. They never
  double-send; `:VibingCancelResume` clears them.
- **`vim.bo[buf].modified` as a save-success proxy** misreads an already-unmodified buffer whose
  `:write` fails (externally deleted file, read-only mount) as success.
- **`.vibing/limit-state.json` is scoped per git root, but the limit is per account.** `get_path`
  resolves through `Git.get_root`, so a worktree under `.vibing/worktrees/<branch>/` keeps its own
  record. A limit observed in the main checkout is invisible to a chat in the worktree, which will
  try an ordinary send and only learn about it by being rejected. `pending_resume.lua` already
  scopes the same way, so this is consistent rather than novel — but `architecture.md` advertises
  concurrent chats across worktrees, which is exactly where it shows.

### Pre-existing issues this work uncovered

Unrelated to scheduled requests, but invisible until now and worth fixing separately:

- `spawn_nvim_instance` omitted `--embed`, so every E2E `rpcrequest` hung forever and the three
  older `tests/e2e/` specs had **never actually executed**. Fixed here (`e2e_helper.lua`), which
  is why their failures are now visible.
- Those three specs also never called `require("vibing").setup()`, so no `:Vibing*` command
  existed in their child instances. `setup()` was added, but they still fail on one impossible
  assertion repeated at five sites: `wait_for_buffer_content(inst, "%.md")` searches buffer
  _text_ for a filename. Repairing it means their real assertions run for the first time, with
  unknown results — and they use the repo root as cwd, so they will need a temp-dir cwd to avoid
  writing real chat files during CI.
