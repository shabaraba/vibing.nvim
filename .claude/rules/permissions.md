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
  on that `ChatBuffer` and reach the hook through `set_active_opts`, keyed by handle_id. A
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
