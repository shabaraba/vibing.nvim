# Codex duplex hook blocks

`codex app-server` reports a PreToolUse refusal through `hook/started` and
`hook/completed`. The decoder emits a `hook_blocked` canonical event with every
`run.entries[].text` reason. The renderer writes a notice immediately; a refused
tool does not make the whole turn fail. Unknown statuses are ignored.

Measured on macOS with codex-cli 0.162.0. The generated JSON schema lists
`running`, `completed`, `failed`, `blocked` and `stopped`. The checked-in capture
is `tests/fixtures/streams/codex-app-server/hook_blocks.json` (ids and paths
sanitized). A denied shell call produced **no commandExecution item at all** and
no standard approval request. The hook id ended in the hook payload's
`tool_use_id`; consequently the id alone cannot reconstruct the command. The
protocol remembers the real permission RPC input on the owning turn, keyed by
that id. Completion consumes the entry; starting another turn clears leftovers.
When RPC cannot connect there is no such input, and the notice reports the hook
failure without guessing a command.

Only `can_use_tool` returning **ask** creates an approval. An explicit deny,
including one matching a permission rule, remains final and never creates a
prompt. Feedback text never authorizes a retry. The script's connection and wait
failures are labeled as failures that approval cannot repair; unrecognized
feedback still has no approval route. The shell script and its three deadlines
are unchanged.

Codex duplex requests the shared handler's retry policy: write a reasoned deny,
retain the actual tool input as the chat's pending approval, let the turn finish,
and use the existing answer path to retry. In-place hook waiting has **not** been
measured for Codex, so this does not enable it or borrow the native approval's
wait measurement. A real E2E run using the old kill-before-prompt path consumed
the chat answer but the next turn never completed. The new path completed both
turns and ran the exact original command. The persisted incomplete-call state
after killing app-server is a suspected cause, not a measured explanation.

This protocol offers only `allow_once` and `deny_once`. Answering records the
existing temporary `:once` permission on that chat; the next hook evaluates deny
rules first and consumes the grant. It writes neither `permissions_allow` nor
`permissions_deny`. Native approvals retain their independent JSON-RPC response
path. Human option-line answers and `nvim_chat_answer_approval` share the usual
chat answer implementation. The policy and observer are selected only for duplex;
`codex exec` retains its existing decoder, options and kill/retry behavior.
If a native approval exposes the retry prompt before the turn finishes, an early
retry answer stays unspent. The user can answer the native prompt first and then
retry the refused call after completion.

`tests/e2e/codex_hook_blocked_spec.lua` drives three real cases: explicit deny,
chat allow_once followed by the same command, and an actually stopped RPC server.
Unit tests cover unknown statuses, fallback reasons, owner/turn isolation,
per-turn cache cleanup, one-time decisions, unchanged oneshot policy and the MCP
answer handler. No `.claude/rules/` changes are needed.
