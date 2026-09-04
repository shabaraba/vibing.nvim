# Chat UI: Subagent Output, Timestamps and AskUserQuestion

Moved out of `.claude/rules/features.md`. The always-loaded rule for each of these is one line in
that file; the reasoning and the traps are here.

## Subagent Output Visibility

The Claude CLI hides everything a subagent says unless it is launched with
`--forward-subagent-text`; without the flag a `Task`/`Agent` call shows only its header and final
result. `agent.subagent.enabled` (default `false`) opts in, and
`modules/subagent_display.lua` renders the forwarded text under the tool header behind a `│` rail
(`show_prefix` adds a `[<subagent_type>]` label per line).

The shape of the stream is what makes this simple, and was verified against the CLI rather than
assumed: subagent contributions arrive as **complete `assistant`/`user` events with a top-level
`parent_tool_use_id`**, never as `stream_event` deltas. So the parent's own streaming text is
untouched, and `cli_event_processor.lua` can buffer per `tool_use_id` in `context._subagent_text`
and flush at `emit_tool_result` — which is what keeps parallel subagents from interleaving.

**The trap:** top-level events carry `"parent_tool_use_id": null`, which `vim.json.decode` turns
into `vim.NIL` — truthy in Lua. Testing the field directly routes every ordinary assistant message
into the subagent buffer and silently stops all tool results from rendering. Go through the
`parent_tool_use_id(msg)` helper, which requires a non-empty string.

Only the subagent's assistant text is surfaced; the prompt echo, thinking blocks, and its nested
tool results stay hidden. `tests/fixtures/subagent_stream.jsonl` is a real captured stream used to
replay the whole path in `cli_event_processor_subagent_spec.lua`.

## Message Timestamps

Chat messages include timestamps in their headers (`## 2025-12-28 14:30:00 User`) for chronology
and search — `/2025-12-28` in Neovim, or `grep "## 2025-12-28" .vibing/chat/*.md` across chat
files. Legacy headers without timestamps (`## User`, `## Assistant`) remain fully supported. User
timestamps are recorded when the message is sent (`<CR>`); Assistant timestamps are recorded when
the response begins (`on_done` callback). Timestamps use the local system timezone (Lua's
`os.date()`).

A message another chat delivered gets its own section kind rather than a `## User`, so a
transcript says who wrote what:

```markdown
## Request <!-- 2026-09-02 08:13:11 from .vibing/chat/orchestrator.md -->

## Report <!-- 2026-09-02 08:14:07 from .vibing/chat/worker-a.md -->

## Notice <!-- 2026-09-02 08:14:16 -->
```

`Request` is a dispatch, `Report` a reply or a completion report, `Notice` a watchdog wake-up
vibing.nvim generated itself. Which of the first two applies is decided by
`orchestration_link.direction`, not guessed from the text. The grammar is
`## <Kind> <!-- <unsent|timestamp>[ from <path>] -->` and lives only in `timestamp.lua`;
`parse_header` is what every reader goes through. Why `extract_role` still answers `user` for all
three: `handbook/architecture/orchestration.md` → "Delivered sections".

Implemented in `lua/vibing/core/utils/timestamp.lua`: `create_header(role, timestamp)`,
`extract_role(line)`, `has_timestamp(line)`, `extract_timestamp(line)`, `is_header(line)`.

## AskUserQuestion Support

Multiple-choice questions render as plain markdown in the chat buffer instead of a native prompt,
so the user can answer with ordinary Vim editing:

```markdown
Which database should we use?

1. PostgreSQL
2. MySQL
3. SQLite
```

That is the whole of it — the question text and the options, appended under the unsent `## User`
header. There is no trailing "press `<CR>` to send" line; only the _approval_ UI has one
(`renderer.lua`). This example used to include one, and `tests/e2e/ask_user_question_spec.lua` was
written against the documentation rather than the renderer, so it waited forever for a string
nothing emits.

Single-select questions render as a numbered list (`1. 2. 3.`); multi-select questions render as a
bullet list (`- - -`). The user deletes unwanted options with standard Vim commands (`dd`, etc.)
and sends the remainder with `<CR>`.

**Implementation:** the primary path is vibing.nvim's own MCP tool
`mcp__vibing-nvim__nvim_ask_user_question` (`claude-plugin/mcp-server/src/tools/chat.ts`), which
the CLI's system prompt instructs the model to use instead of the native tool. Its handler calls
`M.ask_user_question()` in `infrastructure/rpc/handlers/permission.lua`, which cancels the
in-flight turn and renders the choice list via `on_insert_choices`. Because the turn is killed,
the tool's return value never reaches the model — the user's answer arrives as the next `--resume`d
turn's user message, so no Promise/state handling is required.

**The choice list is only staged, so the staging has to be synchronous.** `on_insert_choices`
writes `_pending_choices` and nothing else; the one thing that renders it is `add_user_section()`
at the end of `_handle_response`. But `cancel()` runs the adapter's wrapped `on_done`, and that is
what queues the completion — so a staging deferred by its own `vim.schedule` lands one tick too
late, the completion consumes a nil, and the turn ends cut short with nothing in the buffer to
answer (#649). Neither this callback nor `on_approval_required` may add an inner `vim.schedule`:
both are already on the main thread when `permission.lua` calls them. `on_approval_required` had
always obeyed that rule; `on_insert_choices` was the one that did not.

Rendering from `insert_choices` itself is not the alternative — `### Modified Files` and the patch
comment are appended _before_ the User section, so the diff would land underneath the choices.

Native `AskUserQuestion` is unavailable in headless `claude -p` mode and is opaque to vibing.nvim,
so the PreToolUse hook intercepts and denies it, rendering the same UI as a fallback.

### Codex backend: not available

Codex sessions cannot reach this UI, so `codex_cli.lua` deliberately omits `chat_bufnr` when
registering with `ActiveStreamRegistry`. Two things block it, and neither is fixable from this
side:

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
