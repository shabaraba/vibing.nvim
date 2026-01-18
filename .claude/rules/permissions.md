# Permissions Configuration

vibing.nvim provides comprehensive permission control over what tools Claude can use.

## Permission Modes

```lua
require("vibing").setup({
  permissions = {
    mode = "acceptEdits",  -- "default" | "acceptEdits" | "bypassPermissions"
    allow = { "Read", "Edit", "Write", "Glob", "Grep" },
    deny = { "Bash" },
  },
})
```

**Permission Modes:**

- `default` - Ask for user confirmation before each tool use
- `acceptEdits` - Auto-approve Edit/Write operations, ask for others (recommended)
- `bypassPermissions` - Auto-approve all operations (use with caution)

**Basic Permission Logic:**

- Deny list takes precedence over allow list
- If allow list is specified, only those tools are permitted
- If allow list is empty, all tools except denied ones are allowed
- Denied tools will return an error message when Claude attempts to use them

**Available Tools:** Read, Edit, Write, Bash, Glob, Grep, WebSearch, WebFetch

## Permission System Layers

Three-layer permission control:

1. **Allow/Deny Lists** - Basic tool-level permissions
2. **Permission Modes** - Automation level (default/acceptEdits/bypassPermissions)
3. **Granular Rules** - Path/command/pattern/domain-based fine-grained control

## Granular Permission Rules

For fine-grained control, use permission rules based on paths, commands, patterns, or domains:

```lua
require("vibing").setup({
  permissions = {
    mode = "default",
    rules = {
      -- Allow reading specific paths
      {
        tools = { "Read" },
        paths = { "src/**", "tests/**" },
        action = "allow",
      },
      -- Deny writing to critical files
      {
        tools = { "Write", "Edit" },
        paths = { ".env", "*.secret", "*.key" },
        action = "deny",
        message = "Cannot modify sensitive files",
      },
      -- Allow specific npm/yarn commands
      {
        tools = { "Bash" },
        commands = { "npm", "yarn" },
        action = "allow",
      },
      -- Deny dangerous bash patterns
      {
        tools = { "Bash" },
        patterns = { "^rm -rf", "^sudo", "^dd if=" },
        action = "deny",
        message = "Dangerous command blocked",
      },
      -- Allow specific domains for web tools
      {
        tools = { "WebFetch", "WebSearch" },
        domains = { "github.com", "*.npmjs.com", "docs.rs" },
        action = "allow",
      },
    },
  },
})
```

**Rule Fields:**

- `tools` - Array of tool names to apply the rule to
- `paths` - Glob patterns for file paths (Read/Write/Edit)
- `commands` - Array of allowed/denied command names (Bash)
- `patterns` - Regex patterns for command matching (Bash)
- `domains` - Domain patterns for web requests (WebFetch/WebSearch)
- `action` - "allow" or "deny"
- `message` - Custom error message (optional, for deny rules)

**Rule Evaluation Order:**

Permission rules are evaluated in the following order to ensure security:

1. **Deny rules are evaluated first** - If any deny rule matches, access is immediately blocked
2. **Allow rules are evaluated second** - If no deny rule matches and an allow rule matches, access is granted
3. **Default deny** - If no rules match, access is denied with "No matching allow rule"

**Security Features:**

- **Path Normalization** - All file paths are normalized to absolute paths and symlinks are resolved to prevent directory traversal attacks
- **Pattern Matching** - Glob patterns support `*` (single directory) and `**` (recursive) wildcards
- **Explicit Allow** - When using rules, you must explicitly allow operations (deny-by-default)

## Interactive Permission Builder

Use the `/permissions` (or `/perm`) slash command in chat to interactively configure permissions:

```vim
/permissions
```

This launches an interactive UI that guides you through:

1. Selecting a tool (Read, Edit, Write, Bash, etc.)
2. Choosing allow or deny
3. Optionally specifying Bash command patterns
4. Automatically updating chat frontmatter

The Permission Builder provides a user-friendly alternative to manually editing configuration
or frontmatter.

## Tool Approval UI

vibing.nvim provides an interactive approval UI for tool usage when permission mode is set to `default` or when specific tools are in the `ask` list. Instead of using Agent SDK's console prompts, vibing.nvim presents approval options directly in the chat buffer.

**How It Works:**

1. **Claude requests a tool** - When Claude tries to use a tool that requires approval, the Agent Wrapper sends an `approval_required` event
2. **Approval UI appears in chat** - The tool information and approval options are inserted into the chat buffer as plain text:

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

3. **User edits to select** - Delete unwanted options using Vim's standard editing commands (`dd`, etc.)
4. **Send with `<CR>`** - Press `<CR>` to send the approval decision

**Approval Options:**

- **allow_once** - Allow the tool to execute this one time. Next time Claude tries to use the same tool, approval will be required again.
- **deny_once** - Deny the tool execution this one time. Claude will try an alternative approach. Next time the tool may be allowed.
- **allow_for_session** - Add the tool to the session-level allow list. For the rest of this chat session, the tool will be auto-approved.
- **deny_for_session** - Add the tool to the session-level deny list. For the rest of this chat session, the tool will be auto-denied.

**Key Features:**

- **Natural Vim workflow** - Use standard Vim commands (`dd`, `d{motion}`, etc.) to select approval option
- **Session-level permissions** - `allow_for_session` and `deny_for_session` persist for the entire chat session
- **Detailed context** - Shows tool name and relevant input (command, file path, URL, etc.)
- **Non-invasive** - No special keymaps or UI overlays; works with standard buffer editing
- **AskUserQuestion-like UX** - Consistent with Claude's question-asking interface

**Implementation Details:**

- Agent Wrapper sends `approval_required` event and denies the tool
- Approval UI is inserted into chat buffer as plain markdown with numbered list
- User edits to select option and sends via normal message flow (`<CR>`)
- Buffer parser detects approval response and updates session permissions
- Assistant responds with confirmation message
- Claude retries the tool with updated session permissions
