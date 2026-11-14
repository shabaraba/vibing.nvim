# Queued Prompts as MCP Tools: Question and Approval-Required

Status: **decided, not implemented.** The decision is that a question and an approval request the
model raises are tools of the bundled `vibing-nvim` MCP server, and that the tool never waits.
This records the shape, why the `vibing-question` block is being given up as the primary route, and
what has to be settled before building it.

## Decision

- **Two tools** on the bundled server, names provisional: `nvim_ask_question` for a multiple-choice
  question, `nvim_request_approval` for an approval the model asks for before work it is about to do.
- **A call does not wait.** It validates its arguments, appends an entry to a queue held on the
  Neovim side, and returns at once with text that tells the model to end its turn.
- **vibing drains the queue when the turn ends**, writing each entry under the next unsent
  `## User` section — choices for a question, an approval prompt for an approval — in the order they
  were queued. The answer is the next turn's message, exactly as a `vibing-question` answer is today.
- **The `vibing-question` fence stays as a fallback**, only for a backend whose chat cannot reach
  the tool (see "Who can call it"). It is no longer the route every backend takes.

## Why the block stops being the primary route

A question written as a fenced block is recognised only when it is the last thing the turn wrote
(`question_block.lua`, `find_trailing`). That is correct for refusing a block quoted inside an
example, and it makes the question depend on the model leaving nothing after it.

A real failure: a `stitch-now` chat (`chat-20261113-225312-…`) answered after web searches. The
search tool's own instruction is to end with a `Sources:` list, the model obeyed it, and the list
followed the closing fence. `find_trailing` returned nothing, the JSON stayed in the transcript as
text, and the user answered by reading it. Nothing reported an error: `take_question_block` returns
`false` and `send_message.lua` runs it under `pcall`.

Two older leftovers in the chat logs are the same class: a block whose body was a numbered list and
not JSON (2026-11-03), and one with no closing fence (2026-11-05, plausibly what #955 fixed).
Every one is a formatting obligation put on the model, and any other instruction that makes it
append something to its reply breaks the first of them again. A tool call has no position in the
text, and its arguments are checked against a schema before anything is drawn.

## The queue

- **Keyed by the turn**, held on the turn registry entry the call resolves to, so a turn that is
  cancelled or ends in an error takes its queue with it. Nothing is drawn for a turn that did not
  finish.
- **The caller is found by process id**, through `rpc/hook_scope.lua`, the same resolution
  `nvim_permission_prompt` uses. A call that names no registered process is refused, never
  guessed: a guess would draw a prompt in whichever chat happens to be streaming.
- **The drain is at the call site `take_question_block` has today**, in `send_message.lua`, before
  `### Tokens` and `### Modified Files`. Because the queue does not read the transcript, trailing
  text no longer matters. The entries reach the existing renderers (`insert_choices`, and the
  approval prompt rendering), so what the user sees does not change.
- **Several calls in one turn are merged**: questions into one section with the same cap
  `AskUserQuestion` had (four), approvals as separate prompts, both in call order.
- **The chat reports `asked_question` or `waiting_approval` until its next send**, through the same
  `_stop_reason` path, so an orchestrator answers it as it answers a block today.

## What "approval required" means here

An approval the **model asks for**: "I am about to delete these files — confirm". It is queued,
drawn at the end of the turn and answered by the next message, like a question.

It is **not** the tool-permission gate. The PreToolUse hook's waiting approval (#778) and claude's
`nvim_permission_prompt` stay as they are. A gated tool call has to be held or refused at the moment
the CLI makes it, and a tool that returns immediately cannot do that. Whether the model-raised
approval is also to be honoured as a grant for a later tool call, and how, is not decided.

## Who can call it

The tool needs to know which chat it was called from, and that arrives as `VIBING_PROCESS_ID` in
the MCP server's environment. Measured on 2026-11-14: claude's plugin MCP server inherits it. Read
from the code and not run: codex, grok, commandcode and opencode forward only the RPC port and
`VIBING_NVIM_CONTEXT` to their MCP subprocess, so the id does not reach it.

- **First step: claude only.** The instruction names the tool only where the id reaches the
  server, the same rule the background-process policy follows for `nvim_job_start`; every other
  backend keeps the fenced block.
- **Reaching the others** is a side effect of moving to an HTTP MCP server, where the id travels in
  a header and not in the subprocess environment. That route was measured for claude, codex
  (`exec` and `app-server`) and commandcode: `handbook/architecture/resident-mcp-server.md`.

## Invariants that change when this is built

This change only records the decision; none of the rules below is edited here.

- `permissions.md` → "Asking a Question": "only the last thing a turn wrote is a question" applies
  to the fallback block alone. The line about native `AskUserQuestion` being denied with a reason
  that names the block has to name the tool where the tool is reachable.
- `features.md` → "AskUserQuestion": "a question is a block the model writes, not a tool call" is
  reversed for a backend that can reach the tool.
- `approval-without-kill.md` → "Questions as reply blocks": the reason given there for dropping the
  tool was the cost of holding the turn open. A queued tool holds nothing, so that cost is not
  reintroduced.
- `mcp-integration.md`: the tool prefix and `VIBING_NVIM_MCP_TOOL_PATTERNS` need the new names.

## Not decided

- The tool names, and whether one tool with a `kind` argument is better than two.
- A call after the model has already written a `vibing-question` block in the same turn: which
  wins, and what happens to the block's text in the transcript.
- A subagent calling the tool: it shares its parent's process id, so the entry would land in the
  parent's chat.
- Whether the model obeys "end your turn now" after the tool returns. If it keeps working, the
  entries are still drawn at the end of the turn, only later. `tests/evals/` is where this is
  measured, since it scores the tool calls a turn made and not its prose.
- Whether the model-raised approval also records a grant (see above).
