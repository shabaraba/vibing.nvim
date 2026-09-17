# Permissions: Evaluation Order, the Builder UI and Delegated Approval

Moved out of `.claude/rules/permissions.md`. The user-facing option reference is
`handbook/configuration.md` → "Granular Permission Rules" and "Default Deny Rules"; this file is
the reasoning behind the evaluation order and the two UIs.

## The Three Layers

vibing.nvim controls what tools Claude can use via **Allow/Deny lists** (tool-level permissions),
**Permission Modes** (automation level), and **Granular Rules** (path/command/pattern/domain-based
fine-grained control).

```lua
require("vibing").setup({
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "plan" | "auto" | "dontAsk" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep", "Skill" },
    deny = { "Bash" },
  },
})
```

- `default` - ask for confirmation before every tool use
- `acceptEdits` - auto-approve Edit/Write, ask for others (recommended)
- `plan` - read-only planning mode, no tool execution
- `auto` - background safety classifier minimizes prompts (Claude Code v2.1.83+)
- `dontAsk` - deny instead of prompting (pre-approved tools only)
- `bypassPermissions` - auto-approve everything (isolated environments only)

**Basic logic:** deny list takes precedence over allow list; a non-empty allow list is the only
tools permitted; an empty allow list permits everything except denied tools.

Available tools: Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Skill, Task/Agent.
`Task` and `Agent` are the same subagent launcher under the CLI's old and new names — allow
one of them if you want chats to be able to spawn subagents at all (see
`handbook/architecture/chat-lineage.md`).

## Granular Rules

```lua
require("vibing").setup({
  permissions = {
    mode = "default",
    rules = {
      { tools = { "Read" }, paths = { "src/**", "tests/**" }, action = "allow" },
      {
        tools = { "Write", "Edit" },
        paths = { ".env", "*.secret", "*.key" },
        action = "deny",
        message = "Cannot modify sensitive files",
      },
      { tools = { "Bash" }, commands = { "npm", "yarn" }, action = "allow" },
      -- Lua patterns, NOT regex: "-" is a quantifier, so escape it as "%-"
      { tools = { "Bash" }, patterns = { "^rm%s+%-rf", "^sudo%f[%W]" }, action = "deny" },
      {
        tools = { "WebFetch", "WebSearch" },
        domains = { "github.com", "*.npmjs.com", "docs.rs" },
        action = "allow",
      },
    },
  },
})
```

Fields: `tools` (target tools), `paths` (glob, for Read/Write/Edit), `commands`/`patterns` (Bash),
`domains` (WebFetch/WebSearch), `action` (`allow`/`deny`), `message` (optional, for deny rules).

**Evaluation order (the part worth knowing before editing `can_use_tool.lua`):** deny rules are
checked before the permission mode, the tool-level lists _and_ the session-level allow list. That
last one is the non-obvious constraint — `allow_for_session` records only the bare tool name, so
evaluating it first would let one approved `Bash` call whitelist every later one. Allow rules run
after the tool-level lists. Full field/matching table and the rest of the ordering:
`handbook/configuration.md` → "Granular Permission Rules". `patterns` are **Lua patterns, not regex**.

**Default deny rules:** `permissions.default_deny_rules` (default `true`) prepends bundled deny
rules for destructive Bash commands, defined in
`lua/vibing/core/constants/destructive_commands.lua`. The blocked list and its known gaps live in
`handbook/configuration.md` → "Default Deny Rules".

## Interactive Permission Builder

`/permissions` (or `/perm`) launches a `vim.ui.select()`-driven UI: pick a tool, choose
allow/ask/deny, optionally narrow it with an argument, and the result is written to chat
frontmatter — an alternative to hand-editing config or frontmatter. The allow/ask/deny step shows
what is currently set for that tool, so you can see `Bash(git:*)` is already allowed before adding
another entry.

Which argument a tool takes follows `infrastructure/permissions/matchers.lua`, since that is what
has to parse the result back:

| Tool                         | Argument       | Example                |
| ---------------------------- | -------------- | ---------------------- |
| `Bash`                       | command prefix | `Bash(git:*)`          |
| `Read` / `Write` / `Edit`    | path glob      | `Read(src/**)`         |
| `WebFetch` / `WebSearch`     | domain         | `WebFetch(github.com)` |
| `Glob` / `Grep`              | exact pattern  | `Glob(**/*.ts)`        |
| `Skill` / `StructuredOutput` | none           | `Skill`                |

The last row is deliberate. `matchers` classifies anything else as `unknown_pattern` and never
matches it, so letting the picker build a `Skill(x)` would produce a rule that silently never
fires.

## Tool Approval UI

When permission mode is `default`, or a tool is in the `ask` list, vibing.nvim shows an approval
prompt directly in the chat buffer instead of the CLI's own console prompt (which is unreachable
in headless `claude -p` mode):

```markdown
⚠️ Tool approval required

Tool: Bash
Command: npm install

1. allow_once - Allow this execution only <!-- vibing:req=1789655115-51729-12345 -->
2. deny_once - Deny this execution only <!-- vibing:req=1789655115-51729-12345 -->
3. allow_for_session - Allow for this session <!-- vibing:req=1789655115-51729-12345 -->
4. deny_for_session - Deny for this session <!-- vibing:req=1789655115-51729-12345 -->

Delete every option line except the one you want, then press <CR>.
```

The user deletes unwanted options with standard Vim commands (`dd`, etc.) and sends the remaining
one with `<CR>`. `allow_once`/`deny_once` apply to this call only; `allow_for_session`/
`deny_for_session` persist for the rest of the chat session.

### More than one prompt at a time, and why the lines are marked

A CLI runs its tool calls — and therefore their PreToolUse hooks — **in parallel**. Measured on
claude 2.1.236, one turn's three `Read`s started three hooks 0.54s apart, all three blocking
simultaneously (`tests/perf/hook_concurrency.sh`). So once an approval can be answered without
killing the turn, a chat routinely holds several prompts at once, and every one of them draws the
same `1. allow_once - …`.

The `<!-- vibing:req=… -->` marker is what makes an answer attributable. Nothing resolves by
position or by "the topmost one": people answer out of order, and the third prompt is as likely to
be answered first as the first.

`approval_parser.lua` is the only place that composes that line and the only place that reads it
back — `approval_delegate.option_line` calls the same encoder, because a delegated answer is meant
to be byte-identical to the line a human would have left behind.

**An ambiguous answer is refused and consumes nothing.** Two lines left for one request, or an
unmarked line while several prompts are open, stops the send with a message saying which request
has how many lines. This does change one long-standing behaviour: pressing `<CR>` with the whole
block still in place used to take the first match, which is always `allow_once` — a grant produced
by doing nothing. The refusal is cheap precisely because the hook is still blocked: the user edits
the lines and presses `<CR>` again, where under the old kill-based design a refusal cost a turn.

An approval that reaches its wait limit is **marked expired in place, not deleted** — removing
lines from a buffer the user may be editing moves everything under their cursor. The mark is what
explains why an answer to it is refused.

### Where the prompt is drawn, and why the stream stops while it is open

Under the kill-based design nothing had to decide this. The process died, the turn ended, and
`_handle_response` → `add_user_section` was the single place a prompt was ever drawn. A turn that
keeps running never reaches that point, so two things moved:

- **`on_approval_required` takes a fifth argument, `waiting`.** True on the waiting path, and the
  chat draws the prompt itself (`ChatBuffer:show_approval_prompts`). Drawing unconditionally would
  double-render on the kill path, where `_handle_response` still draws; not drawing at all is the
  silent failure this argument exists to prevent — the prompt is stored, nothing appears, and the
  hook waits out the whole limit against an empty screen.
- **Drawing the prompt closes the assistant section it interrupts**, writing the end timestamp
  `cache_expiry` reads. The turn ending used to be that moment.

**While any prompt is open the chunk buffer stops draining** (`ChatBuffer:append_chunk`). An
append-only buffer cannot hold an input field and a stream of output at the same time: the prompt
is an unsent `## User` section at the end and `flush_chunks` appends at the end too, so anything
flushed under it is read back by `extract_user_message` as the user's next message. What that costs
is bounded by measurement — claude emits no assistant prose while a hook blocks, so what
accumulates is the rendering of tools that ran in parallel.

Answering the **last** prompt opens a `## Assistant` and flushes there; answering one of several
redraws the rest into a new input section and keeps holding. Opening an input section in the first
case would put the held output right back under the input. The same answer clears `_stop_reason`,
which is otherwise only cleared where a new turn starts — and answering in place starts none, so
the chat would call itself `waiting_approval` until its next send.

### Implementation notes

- The PreToolUse hook (`bin/hooks/pre-tool-use.sh`) posts to the RPC server, which dispatches to
  `infrastructure/rpc/handlers/permission.lua`. An `ask` verdict takes one of two shapes, and which
  one is a property of the backend rather than of the call: `_can_wait_for_approval` (the
  descriptor's `measured_wait_floor_sec` against the currently configured wait) travels per turn
  next to `_tool_vocabulary`, so the handler still names no backend. True → `_ask_without_killing`
  withholds the `.res`; false → `cancel_and_deny` kills the process and denies, exactly as before.
- **`_ask_without_killing` registers the withheld response before anything that can throw.** The
  registry is what arms the wait limit, so a failure past that point still ends in a written `.res`
  rather than a hook spinning to the script's own deadline. Drawing is additionally guarded, so a
  failure there does not also cost the watchdog its notification.
- **No chat to ask means deny.** A `.res` nobody can ever answer is a CLI hung inside its own hook.
- **The watchdog is told explicitly** (`completion_notifier.on_approval_waiting`). `VibingResponseDone`
  never fires for a turn that is still running, so an orchestrator would otherwise see `responding`
  until the limit expired.
- `on_approval_required` must be called from the vim main thread (inside `vim.schedule`) — the
  caller ensures this; do not add an inner `vim.schedule` wrapper inside the implementation.
- `_pending_approvals` is set before `add_user_section()` runs, so the approval UI renders at the
  correct position in the chat buffer.
- On the **kill** path the user's answer still becomes a retry instruction sent as a new turn. On
  the waiting path it becomes a verdict for the hook that is still blocked, and no message is sent
  at all (`ChatBuffer:_answer_pending_approval`'s three outcomes).

## An Answer Belongs to the Chat That Was Asked (#667)

The four decisions are recorded on that `ChatBuffer` (`update_session_permissions`), handed to the
next request as `permissions_session_allow` / `permissions_session_deny`, and reach the hook
through `set_active_opts`, which is keyed by turn id — per turn rather than per chat because every
one of these values is re-read from frontmatter on each send, and the lists grow by one entry each
time an approval is answered (`processes-and-turns.md`). They used to be written to a second,
module-level table in `permission.lua` as well — keyed by nothing — so a `deny_once` answered in a
worker chat was consumed by whichever chat called that tool next, and an `allow_for_session`
granted in a throwaway worker applied to every chat in the editor, walking past each one's own
`permissions_ask`. Orchestration makes concurrent chats the normal case, so this was reachable in
ordinary use rather than in a corner.

`build_permission_config` was the only reader of that table: the per-chat lists were already
plumbed all the way to it and then dropped. Note that a `:once` grant is consumed by
`table.remove` on the list it matched in, so sharing that list is what made the grant land on the
wrong chat — being per-chat is a correctness property here, not only an isolation one.

## Delegated Approval

**Another chat can answer a worker's prompt only when the user opted in.** A worker chat that hits
this prompt is `waiting_approval`: its turn was killed, so it can neither continue nor report that
it is stuck, and in an orchestration run the user has to find each blocked worker by hand. With
`agent.orchestration.delegated_approval = true` the orchestrator answers instead, via the MCP tool
`nvim_chat_answer_approval` → `application/chat/approval_delegate.lua`. The default is off because
what it buys is an agent clearing another agent's permission gate, not because of anything in the
implementation.

Set to `"scoped"` instead of `true` (#703), the same call only succeeds for `allow_once` /
`allow_for_session` when the tool and input match a pattern in the _worker's own_
`delegated_scope` frontmatter list — matched with the same `matchers.matches_permission` every
other allow/deny/ask list uses, so there is no second pattern language to learn. A denial always
goes through regardless of scope, since it cannot grant anything the scope would need to bound.
This still requires the same opt-in in `setup()`; it narrows what a `true` delegation would have
allowed, it does not create a new way to reach delegation without one.

The delegated answer takes **exactly the human path**: it writes the chosen option line into the
worker's pending unsent section (replacing the prompt) and calls `ChatBuffer:send_message()`, so
`update_session_permissions`, the `:once` bookkeeping and the retry-message substitution all run
once, in one place. A second implementation of "what an approval means" is the failure this shape
exists to prevent. What differs is the section header — `## Request <!-- … from <orchestrator> -->`
— which is how the worker's transcript records who granted it.
