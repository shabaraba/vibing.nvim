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

1. allow_once - Allow this execution only
2. deny_once - Deny this execution only
3. allow_for_session - Allow for this session
4. deny_for_session - Deny for this session

Please select and press <CR> to send.
```

The user deletes unwanted options with standard Vim commands (`dd`, etc.) and sends the remaining
one with `<CR>`. `allow_once`/`deny_once` apply to this call only; `allow_for_session`/
`deny_for_session` persist for the rest of the chat session.

### Implementation notes

- The PreToolUse hook (`bin/hooks/pre-tool-use.sh`) posts to the RPC server, which dispatches to
  `infrastructure/rpc/handlers/permission.lua`. When the requested tool is in the `ask` list,
  `cancel_and_deny()` immediately cancels the Claude process and sends a deny response to the
  hook.
- `on_approval_required` must be called from the vim main thread (inside `vim.schedule`) — the
  caller ensures this; do not add an inner `vim.schedule` wrapper inside the implementation.
- `_pending_approval` is set before `add_user_section()` runs, so the approval UI renders at the
  correct position in the chat buffer.
- After the user responds, the buffer parser detects the approval response and updates session
  permissions; `hook_request_id` is cleared to prevent double-processing, and the user message is
  replaced with a retry instruction so the new Claude session picks up the updated session-level
  permissions and retries successfully.

## An Answer Belongs to the Chat That Was Asked (#667)

The four decisions are recorded on that `ChatBuffer` (`update_session_permissions`), handed to the
next request as `permissions_session_allow` / `permissions_session_deny`, and reach the hook
through `set_active_opts`, which is keyed by handle_id. They used to be written to a second,
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

The delegated answer takes **exactly the human path**: it writes the chosen option line into the
worker's pending unsent section (replacing the prompt) and calls `ChatBuffer:send_message()`, so
`update_session_permissions`, the `:once` bookkeeping and the retry-message substitution all run
once, in one place. A second implementation of "what an approval means" is the failure this shape
exists to prevent. What differs is the section header — `## Request <!-- … from <orchestrator> -->`
— which is how the worker's transcript records who granted it.
