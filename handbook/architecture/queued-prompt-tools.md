# Queued Prompts as MCP Tools: Question and Approval-Required

Status: **implemented.** A question and a model-raised approval request are tools of the bundled
`vibing-nvim` MCP server, and neither tool waits. This records the shape, why the
`vibing-question` block was given up as the primary route, and what changed on the way in.

## What was built

- `nvim_ask_question` and `nvim_request_approval` in `agent-plugin/mcp-server/src/tools/prompts.ts`,
  handlers in `src/handlers/prompts.ts`, RPC methods `ask_question` / `request_approval` in
  `lua/vibing/infrastructure/rpc/handlers/prompt.lua`.
- The queue lives on `Vibing.TurnEntry` (`turn_registry.push_prompt` / `take_prompts`).
- **The drain point moved one step earlier than this page first proposed.** `TurnRegistry.close`
  runs inside `cli_adapter.finish`, before `send_message._handle_response`, so the entry is already
  gone when the chat layer runs. `finish` takes the queue before `close` and carries it on
  `response._queued_prompts`; `_handle_response` renders it at the same place it calls
  `take_question_block`.
- **Every backend whose transport registers the bundled server forwards `VIBING_PROCESS_ID`**:
  claude by inheritance; codex through `mcp_servers.<name>.env_vars`; grok, opencode and commandcode
  by adding it to their ACP `BOUND_VARS` (opencode's inline oneshot config copies it from the child
  environment). Copilot and Pi have no bundled server and keep the fallback block.
- `nvim_request_approval` is **advisory only**, as decided below: it draws a confirmation block
  with `Proceed` / `Do not proceed` lines, and the next message is the answer. It records no grant
  and does not feed the tool-permission gate. The vocabulary is not `allow_once` / `deny_once`,
  which belongs to the gate and would make an advisory answer indistinguishable from one. The
  options are drawn only when the turn queued a single confirmation — two would make the remaining
  `1. Proceed` ambiguous. The drawn header, reason and human-directed instruction are UI, not an
  answer, so `ChatBuffer:extract_user_message` strips them
  (`approval_parser.strip_confirmation_scaffolding`) and the model receives only the kept line and
  any text the user typed.

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
- **The chat reports `asked_question` until its next send**, through the same `_stop_reason` path.
  A queued confirmation reports that too rather than `waiting_approval`: it is not in the approval
  registry, so `nvim_chat_answer_approval` cannot answer it and the answer is an ordinary message.
  An orchestrator answers both as it answers a block today.

## What "approval required" means here

An approval the **model asks for**: "I am about to delete these files — confirm". It is queued,
drawn at the end of the turn and answered by the next message, like a question.

It is **not** the tool-permission gate. The PreToolUse hook's waiting approval (#778) and claude's
`nvim_permission_prompt` stay as they are. A gated tool call has to be held or refused at the moment
the CLI makes it, and a tool that returns immediately cannot do that. Whether the model-raised
approval is also to be honoured as a grant for a later tool call, and how, is not decided.

## Who can call it

The tool needs to know which chat it was called from, and that arrives as `VIBING_PROCESS_ID` in
the MCP server's environment. Measured on 2026-11-14: claude's plugin MCP server inherits it. At
that time codex, grok, commandcode and opencode forwarded only the RPC port and
`VIBING_NVIM_CONTEXT` to their MCP subprocess, so the id did not reach them — this change adds it
to each forwarding list.

- **The instruction names the tool only where the id reaches the server**, the same rule the
  background-process policy follows for `nvim_job_start`. The first step was claude only; the
  implementation forwards `VIBING_PROCESS_ID` on every transport that registers the bundled server,
  so those backends name the tool too. Copilot and Pi never had the server and keep the block.
- **Reaching the others** in the end needed no HTTP MCP server: each backend's server registration
  can forward one more variable by name (`env_vars`, the ACP `BOUND_VARS`, or, for opencode's
  inline config, a copy from the child environment). The HTTP route remains the cleaner fix for
  identity and is still the one measured in `handbook/architecture/resident-mcp-server.md`.

## Invariants that changed

- `permissions.md` → "Asking a Question": "only the last thing a turn wrote is a question" now
  applies to the fallback block alone, and the native-`AskUserQuestion` denial names the tool where
  it is reachable.
- `features.md` → "AskUserQuestion": a question and a model-raised confirmation are queued tool
  calls; the block is the fallback.
- `approval-without-kill.md` → "Questions as reply blocks": the reason given there for dropping the
  held tool was the cost of holding the turn open. A queued tool holds nothing, so that cost is not
  reintroduced.
- `mcp-integration.md`: the patterns are server-prefix wildcards, so the new names need no literal
  there; they do need `VIBING_PROCESS_ID` forwarded to the server's subprocess.

## Settled while implementing

- Two tools rather than one with a `kind` argument: the approval carries fields a question does not
  (`reason`, `tool`, `input`), and one schema with conditional requirements reads worse to a model.
- A turn that queued a question **and** wrote a fallback block: the queued question is drawn, and
  `take_question_block` still strips the block out of the reply. Both routes lead to
  `insert_choices`, and the queue runs last.

## Still not decided

- A call after the model has already written a `vibing-question` block in the same turn: which
  wins, and what happens to the block's text in the transcript.
- A subagent calling the tool: it shares its parent's process id, so the entry would land in the
  parent's chat.
- Whether the model obeys "end your turn now" after the tool returns. If it keeps working, the
  entries are still drawn at the end of the turn, only later. `tests/evals/` is where this is
  measured, since it scores the tool calls a turn made and not its prose.
- Whether the model-raised approval also records a grant (see above).
