# Permissions

Three layers: **Allow/Deny lists** (tool-level), **Permission Modes** (`default`, `acceptEdits`,
`plan`, `auto`, `dontAsk`, `bypassPermissions`), and **Granular Rules** (path/command/pattern/
domain). Options, examples and the matcher table: `handbook/architecture/permissions.md` and
`handbook/configuration.md` → "Granular Permission Rules".

Deny takes precedence over allow; a non-empty allow list is the only tools permitted; an empty
allow list permits everything except denied tools.

## Invariants

- **Evaluation order in `can_use_tool.lua`: deny rules run before the permission mode, the
  tool-level lists _and_ the session-level allow list.** That last one is the non-obvious
  constraint — `allow_for_session` records only the bare tool name, so evaluating it first would
  let one approved `Bash` call whitelist every later one. Allow rules run after the tool-level
  lists.
- **`patterns` are Lua patterns, not regex.** `-` is a quantifier, so a literal one is `%-`.
- **An answer belongs to the chat that was asked, and to no other** (#667). The four decisions live
  on that `ChatBuffer` and reach the hook through `set_active_opts`, keyed by `turn_id`. A
  module-level table keyed by nothing let a `deny_once` be consumed by whichever chat called that
  tool next. A `:once` grant is consumed by `table.remove` on the list it matched in, so being
  per-chat is a correctness property, not only an isolation one.
- **`on_approval_required` must not add an inner `vim.schedule`.** The caller already runs it on
  the main thread. `_pending_approval` is set before `add_user_section()` so the UI renders at the
  right position.
- **A delegated approval takes exactly the human path** — it writes the chosen option line into
  the worker's unsent section and calls `ChatBuffer:send_message()`, so
  `update_session_permissions`, the `:once` bookkeeping and the retry-message substitution all run
  once, in one place. A second implementation of "what an approval means" is the failure this
  shape exists to prevent. Refused unless `agent.orchestration.delegated_approval` is set.
- **The Permission Builder must not offer an argument to a tool `matchers.lua` cannot parse.**
  `Skill` / `StructuredOutput` take none; anything else is classified `unknown_pattern` and never
  matches, so a `Skill(x)` rule would silently never fire.

`permissions.default_deny_rules` (default `true`) prepends the bundled destructive-Bash deny rules
from `lua/vibing/core/constants/destructive_commands.lua`.

## Waiting for an Approval

The hook blocks until a human answers, instead of the CLI being killed and the answer coming back
as a new turn (#778). The mechanism, the measurements and the two limits they were taken under:
`handbook/architecture/approval-without-kill.md`.

- **Three deadlines, one source.** `permissions.approval_wait_sec` <
  `bin/hooks/pre-tool-use.sh`'s own wait < each backend's registered hook timeout, all derived in
  `hooks/wait_budget.lua`. The last inequality is not tidiness: **every CLI measured fails open
  past its own hook timeout**, running the tool with no verdict at all. A fourth deadline bounds
  the whole thing from above — claude aborts a silent MCP tool call at 1800s, and
  `nvim_ask_user_question` rides that path rather than the hook's.
- **Waiting is enabled per backend by a _measurement_, not a flag.** `hook.measured_wait_floor_sec`
  is the longest a hook was observed blocking on that CLI without being cut, and a backend with
  none keeps today's kill-and-retry. Raising `approval_wait_sec` past a backend's floor turns the
  feature off for that backend rather than waiting past the evidence.
- **A pending approval is answered exactly once, and every one of them is eventually answered.**
  `rpc/pending_approvals.lua` has four ways out and no fifth: the human answers, the limit expires,
  the chat goes away, Neovim exits. A withheld `.res` that is never written is a CLI hanging inside
  its own hook.
- **Expiry denies one tool call, kills nothing, and spends no permission.** Hooks run concurrently
  (measured: three in one turn, overlapping), so a kill on expiry would take the turn the user is
  in the middle of answering a _different_ prompt for. The limit **answers `deny`** rather than
  giving up on waiting — leaving an approval unanswered is choosing refusal by inaction, and every
  description of the limit should say so. The prompt itself keeps its options and stays spendable
  afterwards; only the route changes, to `retry_as_new_turn`. Refusing to spend it makes waiting
  worse than the kill design for the long absence the limit exists to survive.
- **An approval the user answered in place writes `allow`, not `defer`** — the one exception to
  "only vibing-nvim's own MCP tools get `allow`" (`architecture.md`). The tool being asked about is
  usually one this turn's `--allowedTools` does not cover (that is _why_ it was asked about), and
  the argv cannot change mid-turn, so `defer` would have the CLI's gate refuse what the human just
  approved. The grant is scoped to the single `request_id` a human looked at and is consumed by one
  hook invocation. **What it costs is the allowlist, and only that** — the gate ordering stated in
  `architecture.md` applies to this `allow` unchanged. vibing's own `permissions.deny` never
  reaches this path at all: `can_use_tool.lua` returns `deny`, never `ask`, so a call matching it
  never becomes an approval.
- **A chat waiting for an approval reports `waiting_approval`, not `responding`**, even though its
  turn is still open. `chat_status` reads the pending-approval registry rather than `_stop_reason`,
  which keeps the previous turn's value until the next send.
- **The waiting `request_id`s travel as a query, never on the notification or in the transcript.**
  `chat_status.pending_approvals` is the one source, surfaced as `waiting_approvals` on
  `nvim_chat_list` and `nvim_get_buffer`. A notification is a snapshot and goes stale while the
  orchestrator decides; the `<!-- vibing:req=... -->` markers exist to attribute a human's `<CR>`,
  and reading them from code is the text-heuristic failure a status field exists to replace.
- **"Is an approval pending" is asked of `pending_approvals`, never of `_pending_approvals`.** The
  render list deliberately keeps its entries after a killed turn, so keying on it holds every later
  turn's output forever, and using it to exempt a delegated answer kills a running turn.
- **Every blocked hook is released before the CLI serving it is stopped, at every exit**:
  `:VibingCancel`, the chat's `BufUnload`, sending a new message instead of answering, the turn
  ending, `VimLeavePre`. A missed exit leaves the hook spinning to the script's own deadline and
  then explaining itself as a timeout that did not happen.
- **A delegated answer is exempt from the "chat is responding" guard only while its hook is
  actually blocked**, never because a prompt is still drawn.
