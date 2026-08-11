# Permissions Configuration

vibing.nvim controls what tools Claude can use via three layers: **Allow/Deny lists** (tool-level
permissions), **Permission Modes** (automation level), and **Granular Rules** (path/command/
pattern/domain-based fine-grained control).

## Permission Modes

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

Available tools: Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch, Skill.

## Granular Permission Rules

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

**Evaluation order:** deny rules are checked first — before the permission mode and the tool-level
lists, so they hold under `mode = "auto"` and for always-allowed tools (`bypassPermissions` is the
one deliberate way past them) → allow rules after the tool-level lists → default deny if nothing
matches ("No matching allow rule"). Paths are normalized to absolute, symlink-resolved paths
before matching (prevents traversal attacks); glob patterns support `*` (single directory) and
`**` (recursive). `patterns` are **Lua patterns, not regex**.

**Default deny rules:** `permissions.default_deny_rules` (default `true`) prepends bundled deny
rules for destructive Bash commands — `rm -rf /` or `$HOME`, `sudo`/`doas`, raw device writes
(`dd`/`mkfs`), `chmod -R 777`, and force-pushing main/master. They are defined in
`lua/vibing/core/constants/destructive_commands.lua`; see `docs/configuration.md` → "Default Deny
Rules" for the list and its known gaps. The approval UI is the last line of defence, not the
primary one — the deterministic boundary comes first.

## Interactive Permission Builder

`/permissions` (or `/perm`) launches a `vim.ui.select()`-driven UI: pick a tool, choose allow/deny,
optionally specify a Bash command pattern, and the result is written to chat frontmatter — an
alternative to hand-editing config or frontmatter.

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

**Implementation notes:**

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
