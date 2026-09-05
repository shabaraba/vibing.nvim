# Features

Each entry is the invariant that is easy to break from the code, plus where the reasoning lives.
Read the linked file before changing that path.

## Usage Limits and Scheduled Requests

`handbook/features/usage-limits.md`

- **`.vibing/limit-state.json` is scoped to the backend that hit the limit.** Writers ask
  `factory.agent_id(adapter)` about the adapter that actually ran; readers with no adapter yet
  (`<CR>`, `:VibingSchedule`, `:VibingCancelResume`) predict one with `Modes.resolve_agent`. An
  unscoped read parks codex chats behind a claude limit.
- **A parked message stays in the chat's own unsent `## User` section.** It is never copied into
  `.vibing/pending-resume.json`, so it stays editable and deleting it cancels the send.
- **Every field of the three rate-limit signals is optional.** None of the payload shapes is
  documented, so a schema change must degrade the feature, not break the stream.
- Both features spend tokens unattended, so `auto_resume_on_limit.enabled` defaults to `false`.
- **Giving up on the retry budget writes one line into the chat's own buffer, and that write is
  not a send.** `auto_resume.announce_gave_up` edits the buffer directly and saves it; it must
  never route through `ProgrammaticSender.send` / `ChatBuffer:send_message()`, which would start a
  new CLI turn and spend tokens exactly where the budget exists to stop that. Forwarding the same
  line to `orchestrated_by` is the one exception, and deliberately unconditional on
  `chat_notifications.enabled`: a chat auto-resume gave up on will never resume itself, the same
  "cannot leave this stop on its own" shape as `asked_question` / `waiting_approval` / `error`.

## Subagent Output Visibility

`handbook/features/chat-ui.md`

- **Never test `parent_tool_use_id` directly.** Top-level events carry
  `"parent_tool_use_id": null`, which `vim.json.decode` makes `vim.NIL` — truthy in Lua. Go
  through the `parent_tool_use_id(msg)` helper, which requires a non-empty string. Testing the
  field routes every ordinary assistant message into the subagent buffer and silently stops all
  tool results from rendering.

## AskUserQuestion

`handbook/features/chat-ui.md`

- **Neither `on_insert_choices` nor `on_approval_required` may add an inner `vim.schedule`.** Both
  are already on the main thread when `permission.lua` calls them, and a deferred staging lands
  after the completion has consumed it — the turn ends with nothing in the buffer to answer (#649).
- **Codex cannot reach this UI**, so `codex_cli.lua` deliberately omits `chat_bufnr` when
  registering with `ActiveStreamRegistry`. The ordinary tool-approval flow still works there; it
  routes on `handle_id`.

## Message Timestamps and Delivered Sections

`handbook/features/chat-ui.md`

- **The header grammar `## <Kind> <!-- <unsent|timestamp>[ from <path>] -->` is defined only in
  `timestamp.lua`**, and every reader goes through `parse_header`. `Request` / `Report` / `Notice`
  are chosen by `orchestration_link.direction`, never guessed from the text.
- Legacy headers with no timestamp (`## User`, `## Assistant`) stay supported.

## Code Tour and Debugger Analysis

`handbook/features/editor-integration.md`

- **`nvim_win_open_file` restores focus before returning**, so carry the `winnr` into
  `nvim_set_cursor`. Without it the chat's cursor moves — and succeeds, so the tour looks like it
  is working while the code window never moves.
- **`nvim_set_qflist` pushes a new list, so a tour calls it exactly once**, or `:cnext` walks a
  different list than the one being narrated.
- **Every nvim-dap entry point reports "not installed" / "no session" rather than erroring**, and
  a handler issuing several DAP requests spends **one shared `vim.wait` budget** across them
  (`deadline()` in `dap.lua`), not one per request.
