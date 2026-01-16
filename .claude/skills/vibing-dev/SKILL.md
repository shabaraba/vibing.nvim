---
name: vibing-dev
description: Complete workflow automation for vibing.nvim development - worktree creation, LSP analysis, build/test execution, and PR creation
---

# vibing-dev Skill

This skill automates the complete development workflow for vibing.nvim plugin development.

## When to Use This Skill

Use this skill when:

- Starting a new feature implementation
- Fixing bugs in vibing.nvim
- Refactoring existing code
- Adding tests or documentation

**IMPORTANT: Only use this skill when working ON vibing.nvim itself, not when using vibing.nvim to work on other projects.**

## Available Workflows

### 1. feature-branch - New Feature Development

Complete workflow for implementing new features:

1. **Create development environment**
   - Use `:VibingChatWorktree <branch-name>` (NOT manual `git worktree`)
   - Automatically sets up configs and symlinks node_modules

2. **Analyze codebase**
   - Use `mcp__vibing-nvim__nvim_load_buffer` to load files in background
   - Use `mcp__vibing-nvim__nvim_lsp_*` tools for code analysis (NOT Serena)
   - Always pass `rpc_port: 9876` to target correct Neovim instance

3. **Implement feature**
   - Follow vibing.nvim's architecture patterns
   - Keep files under 100 lines (200 lines max)
   - Single responsibility principle

4. **Build and test**
   - Run `npm run build`
   - Run `npm test`
   - Fix any errors (max 3 attempts, then ask user)

5. **Create PR**
   - Use GitHub API (NOT `gh` CLI in Claude Code Web environment)
   - Semantic commit messages (English)
   - PR title in English, description in Japanese

**Example invocation:**

```
User: "I want to add a new slash command /analyze to vibing.nvim"
Agent: I'll help you implement the /analyze slash command using the vibing-dev workflow.

Step 1: Creating development environment...
[Uses :VibingChatWorktree feat/add-analyze-command]

Step 2: Analyzing existing slash command implementation...
[Loads and analyzes lua/vibing/presentation/chat/slash_commands/ files]

Step 3: Implementing the feature...
[Creates new command file following existing patterns]

Step 4: Building and testing...
[Runs npm run build && npm test]

Step 5: Ready for PR...
[Suggests commit message and PR template]
```

### 2. debug-issue - Bug Fixing Workflow

Systematic approach to debugging and fixing issues:

1. **Reproduce and identify the issue**
   - Read issue description
   - Locate related code using LSP tools

2. **Analyze root cause**
   - Use `mcp__vibing-nvim__nvim_lsp_references` to find all usage
   - Use `mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming` for callers
   - Check diagnostics with `mcp__vibing-nvim__nvim_diagnostics`

3. **Implement fix**
   - Minimal changes principle
   - Add regression tests if applicable

4. **Verify fix**
   - Run affected tests
   - Build successfully
   - Manual testing if needed

**Example invocation:**

```
User: "There's a bug where :VibingChat opens multiple windows"
Agent: I'll debug this issue using the vibing-dev workflow.

Step 1: Locating the issue...
[Loads lua/vibing/presentation/chat/controller.lua]

Step 2: Analyzing call hierarchy...
[Uses LSP to trace window creation logic]

Step 3: Implementing fix...
[Modifies window creation to check for existing windows]

Step 4: Verifying fix...
[Runs build and tests, suggests manual testing steps]
```

### 3. refactor - Code Refactoring Workflow

Safe refactoring with comprehensive analysis:

1. **Analyze current implementation**
   - Read target files
   - Map dependencies using LSP
   - Identify refactoring opportunities

2. **Design new structure**
   - Follow vibing.nvim architecture patterns
   - Ensure backward compatibility where needed

3. **Implement refactoring**
   - Incremental changes
   - Maintain tests passing at each step

4. **Verify integrity**
   - All tests pass
   - No regressions
   - Code quality improved

**Example invocation:**

```
User: "Refactor the permission system to be more modular"
Agent: I'll refactor the permission system using best practices.

Step 1: Analyzing current structure...
[Loads bin/lib/permissions/*.ts files, analyzes dependencies]

Step 2: Designing modular structure...
[Proposes new file structure with separation of concerns]

Step 3: Implementing refactoring...
[Incrementally extracts modules while maintaining compatibility]

Step 4: Verifying all tests pass...
[Runs npm test, checks for regressions]
```

### 4. test-feature - Test Implementation Workflow

Add comprehensive tests for existing or new features:

1. **Understand feature behavior**
   - Read implementation code
   - Identify test scenarios

2. **Write tests**
   - Unit tests for individual functions
   - Integration tests for workflows
   - Follow existing test patterns

3. **Verify coverage**
   - Run tests
   - Check coverage reports
   - Add missing test cases

**Example invocation:**

```
User: "Add tests for the mention system"
Agent: I'll create comprehensive tests for the mention feature.

Step 1: Analyzing mention implementation...
[Loads bin/lib/mention/*.ts files]

Step 2: Writing test cases...
[Creates tests/mention.test.mjs following existing patterns]

Step 3: Running tests...
[Executes npm test, verifies all tests pass]
```

## Tool Priority Rules

When using this skill, ALWAYS follow these tool priorities:

### ✅ MUST USE (Highest Priority)

**For LSP operations:**

- `mcp__vibing-nvim__nvim_lsp_definition`
- `mcp__vibing-nvim__nvim_lsp_references`
- `mcp__vibing-nvim__nvim_lsp_hover`
- `mcp__vibing-nvim__nvim_diagnostics`
- `mcp__vibing-nvim__nvim_lsp_document_symbols`
- `mcp__vibing-nvim__nvim_lsp_type_definition`
- `mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming`
- `mcp__vibing-nvim__nvim_lsp_call_hierarchy_outgoing`

**For buffer operations:**

- `mcp__vibing-nvim__nvim_load_buffer` - Load files without window switching
- `mcp__vibing-nvim__nvim_get_buffer` - Read buffer content
- `mcp__vibing-nvim__nvim_list_buffers` - List all buffers

**For worktree management:**

- `:VibingChatWorktree` via `mcp__vibing-nvim__nvim_execute`

**For file operations:**

- Agent SDK's Read, Edit, Write tools (NOT vibing-nvim MCP tools)

### ❌ NEVER USE

- Serena's LSP tools (`mcp__serena__*`) - Analyzes stale file copies
- Manual `git worktree` commands - Missing environment setup
- `gh` CLI for PR creation in Web environment - Use GitHub REST API

### ⚠️ CRITICAL REQUIREMENTS

1. **Always pass `rpc_port: 9876`** to vibing-nvim MCP tools
2. **Use nvim_load_buffer** before LSP operations on non-active files
3. **Check if you're in Claude Code Web environment** before choosing Git/GitHub tools

## Architecture Guidelines

When implementing features, follow these vibing.nvim architecture patterns:

### File Organization

```
lua/vibing/
├── core/              # Core utilities (config, logger, etc.)
├── domain/            # Business logic entities
├── application/       # Use cases and workflows
├── infrastructure/    # External integrations (git, rpc, etc.)
└── presentation/      # UI and commands
```

### Naming Conventions

- **NO temporal prefixes/suffixes**: Never use `New`, `Old`, `Temp`, `V2`, `Final`, `Optimized`
- **Descriptive names**: Clearly indicate purpose and responsibility
- **Consistency**: Follow existing patterns in the codebase

### Module Size Limits

- **Target**: 100 lines per file
- **Maximum**: 200 lines per file
- **If exceeding**: Split into smaller, focused modules

### Error Handling

- **3-attempt rule**: If build/test fails 3 times, report to user and ask for help
- **Informative messages**: Always explain what went wrong and what was attempted
- **Graceful degradation**: Fail safely when possible

## Common Pitfalls to Avoid

1. **Using wrong LSP tools**
   - ❌ `mcp__serena__find_symbol` - Analyzes separate file copies
   - ✅ `mcp__vibing-nvim__nvim_lsp_*` with `rpc_port` - Connects to running instance

2. **Forgetting rpc_port parameter**
   - ❌ `mcp__vibing-nvim__nvim_list_windows({})`
   - ✅ `mcp__vibing-nvim__nvim_list_windows({ rpc_port: 9876 })`

3. **Manual worktree operations**
   - ❌ `git worktree add .worktrees/feature-branch`
   - ✅ `:VibingChatWorktree feature-branch`

4. **Window switching for LSP analysis**
   - ❌ `nvim_execute("edit file.ts")` then `nvim_execute("bp")`
   - ✅ `nvim_load_buffer({ filepath: "file.ts" })`

5. **Making assumptions instead of asking**
   - ❌ Implementing without clarifying requirements
   - ✅ Use AskUserQuestion tool to clarify before major decisions

## Workflow Execution Steps

When the user invokes this skill:

1. **Identify the workflow type** (feature-branch, debug-issue, refactor, test-feature)
2. **Confirm understanding** with the user before starting
3. **Execute each step** of the workflow sequentially
4. **Report progress** after each major step
5. **Handle errors** gracefully (3-attempt rule)
6. **Ask for help** when stuck or uncertain

## Example Full Workflow

```
User: "Implement a new /stats command that shows chat statistics"

Agent: I'll implement the /stats command using the feature-branch workflow.

[Step 1: Environment Setup]
⏺ mcp__vibing-nvim__nvim_execute({ command: "VibingChatWorktree feat/add-stats-command", rpc_port: 9876 })
✓ Development environment created

[Step 2: Codebase Analysis]
⏺ mcp__vibing-nvim__nvim_load_buffer({ filepath: "lua/vibing/presentation/chat/slash_commands/init.lua" })
⏺ mcp__vibing-nvim__nvim_lsp_document_symbols({ bufnr: <loaded_bufnr>, rpc_port: 9876 })
✓ Analyzed existing slash command patterns

[Step 3: Implementation]
⏺ Write(lua/vibing/presentation/chat/slash_commands/stats.lua)
⏺ Edit(lua/vibing/presentation/chat/slash_commands/init.lua) [register new command]
✓ Implemented /stats command following existing patterns

[Step 4: Build & Test]
⏺ Bash("npm run build")
⏺ Bash("npm test")
✓ All tests passing, build successful

[Step 5: Ready for Review]
Feature implemented successfully!

Suggested commit message:
feat: add /stats slash command for chat statistics

Would you like me to create a pull request?
```

## Success Criteria

A workflow is considered successful when:

- ✅ All code follows vibing.nvim architecture patterns
- ✅ Files stay under size limits (100-200 lines)
- ✅ Build completes without errors
- ✅ All tests pass
- ✅ No LSP diagnostics errors (warnings acceptable)
- ✅ Changes are documented if user-facing
- ✅ Commit message follows Semantic Commit convention

## Getting Help

If you encounter issues while using this skill:

1. **Check the CLAUDE.md** in vibing.nvim root for detailed guidelines
2. **Review ADRs** in `docs/adr/` for architectural decisions
3. **Ask the user** if uncertain about requirements or approach
4. **Report blockers** after 3 failed attempts to resolve

---

**Remember**: This skill is designed to make vibing.nvim development efficient and consistent. Always prioritize code quality over speed, and don't hesitate to ask questions!
