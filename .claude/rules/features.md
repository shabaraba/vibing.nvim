# Features

## Auto-Resume on Usage Limit

When a turn is rejected because the plan's usage limit is exhausted, vibing.nvim can park the chat
and send a single continuation message once the limit resets. Opt-in via
`agent.auto_resume_on_limit.enabled` (default `false` — it spends tokens unattended).

Detection merges three signals in `lua/vibing/core/utils/rate_limit.lua`: the CLI's
`rate_limit_event` stream line (the **only** source of `resetsAt`), the `StopFailure` hook filtered
to `error_type = rate_limit` (confirms the turn died, no timestamp), and the error text as a
fallback. None of these payload shapes is officially documented, so every field is optional and a
schema change degrades the feature instead of breaking the stream.

Pending resumes persist to `.vibing/pending-resume.json` and are re-armed on `setup()`, since a
five-hour reset usually outlives the Neovim session. Safeguards: `max_retries` (default 1) per
limit hit, never overwriting an unsent `## User` message, and an 8-day sanity ceiling on the reset
timestamp. Concurrently parked chats all fire at once by design. See `docs/configuration.md` →
"Auto-Resume on Usage Limit".

**Implementation:** `application/chat/auto_resume.lua` (scheduler),
`infrastructure/storage/pending_resume.lua` (persistence),
`infrastructure/rpc/handlers/rate_limit.lua` (StopFailure receiver), `bin/hooks/stop-failure.sh`.

## Message Timestamps

Chat messages include timestamps in their headers (`## 2025-12-28 14:30:00 User`) for chronology
and search — `/2025-12-28` in Neovim, or `grep "## 2025-12-28" .vibing/chat/*.md` across chat
files. Legacy headers without timestamps (`## User`, `## Assistant`) remain fully supported. User
timestamps are recorded when the message is sent (`<CR>`); Assistant timestamps are recorded when
the response begins (`on_done` callback). Timestamps use the local system timezone (Lua's
`os.date()`).

Implemented in `lua/vibing/utils/timestamp.lua`: `create_header(role, timestamp)`,
`extract_role(line)`, `has_timestamp(line)`, `extract_timestamp(line)`, `is_header(line)`.

## AskUserQuestion Support

Multiple-choice questions render as plain markdown in the chat buffer instead of a native prompt,
so the user can answer with ordinary Vim editing:

```markdown
Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite

Please answer the question and press `<CR>` to send.
```

Single-select questions render as a numbered list (`1. 2. 3.`); multi-select questions render as a
bullet list (`- - -`). The user deletes unwanted options with standard Vim commands (`dd`, etc.)
and sends the remainder with `<CR>`.

**Implementation:** the primary path is vibing.nvim's own MCP tool
`mcp__vibing-nvim__nvim_ask_user_question` (`mcp-server/src/tools/chat.ts`), which the CLI's
system prompt instructs the model to use instead of the native tool. Its handler calls
`M.ask_user_question()` in `infrastructure/rpc/handlers/permission.lua`, which cancels the
in-flight turn and renders the choice list via `on_insert_choices`. Because the turn is killed,
the tool's return value never reaches the model — the user's answer arrives as the next `--resume`d
turn's user message, so no Promise/state handling is required.

Native `AskUserQuestion` is unavailable in headless `claude -p` mode and is opaque to vibing.nvim,
so the PreToolUse hook intercepts and denies it, rendering the same UI as a fallback.

**Codex backend: not available.** Codex sessions cannot reach this UI, so `codex_cli.lua`
deliberately omits `chat_bufnr` when registering with `ActiveStreamRegistry`. Two things block it,
and neither is fixable from this side:

- Codex takes no system prompt (context and language are prepended to the user prompt instead), so
  there is no place to hand the model the `chat_bufnr` the tool needs.
- Registering the MCP server per run via `-c mcp_servers.*` would not help. Headless `codex exec`
  auto-cancels MCP tool calls at the approval prompt — stdin is closed, so EOF reads as a denial —
  unless it runs with `--dangerously-bypass-approvals-and-sandbox`, which vibing.nvim only passes
  in `bypassPermissions` mode. See [openai/codex#24135][codex-24135].

What still works on Codex is the ordinary tool-approval flow (the `ask` permission list): it routes
on `handle_id`, not `chat_bufnr`. Only the question-list UI is missing. Revisit if the upstream
issue is resolved.

[codex-24135]: https://github.com/openai/codex/issues/24135
