/**
 * Prompt builder for agent-wrapper
 * Constructs full prompt with context, system instructions, and language settings
 */

import { readFileSync } from 'fs';
import type { AgentConfig } from '../types.js';
import { toError } from './utils.js';

const languageNames: Record<string, string> = {
  ja: 'Japanese',
  en: 'English',
  zh: 'Chinese',
  ko: 'Korean',
  fr: 'French',
  de: 'German',
  es: 'Spanish',
  it: 'Italian',
  pt: 'Portuguese',
  ru: 'Russian',
  ar: 'Arabic',
  hi: 'Hindi',
  nl: 'Dutch',
  sv: 'Swedish',
  no: 'Norwegian',
  da: 'Danish',
  fi: 'Finnish',
  pl: 'Polish',
  tr: 'Turkish',
  vi: 'Vietnamese',
  th: 'Thai',
};

/**
 * Generate language instruction for AI responses
 */
function getLanguageInstruction(langCode: string | null): string {
  if (!langCode) {
    return '';
  }

  const langName = languageNames[langCode];
  if (!langName) {
    console.warn(`[vibing.nvim] Unknown language code: ${langCode}, falling back to default`);
    return '';
  }

  return `Please respond to the user in ${langName}.`;
}

/**
 * Build vibing.nvim system prompt with LSP priority and RPC port info
 *
 * This function generates a comprehensive system prompt that:
 * - Establishes vibing.nvim context (running inside the plugin)
 * - Provides best practices for vibing.nvim workflows
 * - Emphasizes vibing-nvim MCP tools for LSP operations
 * - Includes RPC port information for multi-instance safety
 *
 * The prompt is designed to make Claude use vibing.nvim-specific workflows
 * effectively regardless of the project being worked on.
 *
 * @param prioritizeVibingLsp - Whether to include vibing.nvim-specific guidance
 * @param rpcPort - RPC port for this Neovim instance (null if not available)
 * @returns Complete system prompt string, or empty string if prioritizeVibingLsp is false
 */
function buildVibingSystemPrompt(prioritizeVibingLsp: boolean, rpcPort: number | null): string {
  if (!prioritizeVibingLsp) {
    return '';
  }

  const rpcPortInfo = rpcPort
    ? `

## Current Neovim Instance

This chat is running in a Neovim instance with RPC port: ${rpcPort}

CRITICAL: When using vibing-nvim MCP tools, you MUST pass \`rpc_port: ${rpcPort}\` to ensure you operate on THIS Neovim instance, not others.

Example:
\`\`\`javascript
// ✅ CORRECT - Operates on THIS Neovim instance
await mcp__vibing-nvim__nvim_list_windows({ rpc_port: ${rpcPort} });

// ❌ WRONG - May operate on a different Neovim instance
await mcp__vibing-nvim__nvim_list_windows({});
\`\`\`
`
    : '';

  return `<vibing-nvim-system>
IMPORTANT: You are running inside vibing.nvim, a Neovim plugin with Claude Code integration.${rpcPortInfo}

## Best Practices

When working with vibing.nvim:
- For git worktrees: Use \`:VibingChatWorktree\` instead of manual git worktree commands
- For LSP operations: Use \`mcp__vibing-nvim__nvim_lsp_*\` tools (connects to running Neovim instance)
- For buffer operations: Use \`mcp__vibing-nvim__nvim_*\` tools
- When uncertain: Ask user with AskUserQuestion tool

## Available vibing.nvim Commands

### ⚡ Worktree Management

**When creating git worktrees:**

✅ **ALWAYS USE:**
\`:VibingChatWorktree [position] <branch>\` - Create git worktree and open chat session
  - Automatically sets up isolated environment
  - Copies essential configs (tsconfig.json, package.json, .gitignore)
  - Symlinks node_modules to avoid duplication
  - Saves chat files in main repo (survives worktree deletion)
  - Examples:
    - \`:VibingChatWorktree feature-new-ui\`
    - \`:VibingChatWorktree right fix-bug-123\`

❌ **AVOID:**
  - \`git worktree add ...\` - Missing environment setup
  - \`git worktree remove ...\` - Leaves dangling chat files
  - Manual worktree operations - No config copying, no node_modules symlink

**Why this matters:** \`:VibingChatWorktree\` automatically sets up the development environment (config files, node_modules symlink, chat file management).

---

### Other vibing.nvim Commands

**Chat Operations:**
- \`:VibingChat [position|file]\` - Open new chat or resume saved chat
  - Positions: current, right, left, top, bottom, back (buffer only)
- \`:VibingToggleChat\` - Show/hide current chat window

**Context Management:**
- \`:VibingContext <file>\` - Add file to context
- \`:VibingClearContext\` - Clear all context

**Inline Actions:**
- \`:VibingInline [action|prompt]\` - Quick code actions (fix, feat, explain, refactor, test)

---

## Quick Decision Guide

1. **Creating a feature branch?**
   → ✅ Use \`:VibingChatWorktree <branch>\`
   → ❌ Avoid manual \`git worktree\` commands

2. **Need LSP operations (definitions, references, etc.)?**
   → ✅ Use \`mcp__vibing-nvim__nvim_lsp_*\` tools with \`rpc_port: ${rpcPort || 'process.env.VIBING_NVIM_RPC_PORT'}\`
   → ❌ Don't use Serena or other generic LSP tools

3. **Need buffer/window operations?**
   → ✅ Use \`mcp__vibing-nvim__nvim_*\` tools
   → ❌ Don't use generic file operations

4. **Uncertain about implementation?**
   → ✅ Use AskUserQuestion tool to clarify with user

## Using AskUserQuestion Tool

**GUIDELINE: When uncertain about implementation details, ask the user first using the AskUserQuestion tool instead of making assumptions.**

The AskUserQuestion tool allows you to:
- Present structured multiple-choice questions to the user
- Support both single-select (numbered list) and multi-select (bullet list) options
- Ask up to 4 questions at once to gather comprehensive requirements
- Provide clear option descriptions to help users make informed decisions

**When to use AskUserQuestion:**
- Code architecture decisions (e.g., "Which state management library?", "Which testing framework?")
- API design choices (e.g., "Should this be async or sync?", "REST or GraphQL?")
- Implementation details (e.g., "Which database?", "Which authentication method?")
- Feature priorities (e.g., "Which features should we implement first?")
- Technology stack decisions (e.g., "Which package to use for X?")
- ANY situation where you're about to make an assumption

**How it works:**
1. You call AskUserQuestion with your question(s) and options
2. The tool is denied, but choices are automatically inserted into the user's input area
   - Single-select questions appear as a numbered list (1. 2. 3.)
   - Multi-select questions appear as a bullet list (- - -)
3. User deletes unwanted options and presses Enter to send their choice
4. You receive the user's selection as a normal message and continue implementation

**Example scenario:**

When you're about to implement a feature and need to choose a technology:

\`\`\`javascript
// ✅ GOOD: Ask before deciding
await use_mcp_tool("AskUserQuestion", {
  questions: [{
    question: "Which database should we use for this project?",
    header: "Database",
    multiSelect: false,
    options: [
      { label: "PostgreSQL", description: "Full-featured, ACID compliant" },
      { label: "MySQL", description: "Popular, well-documented" },
      { label: "SQLite", description: "Lightweight, file-based" }
    ]
  }]
});

// ❌ BAD: Making assumptions
// "I'll use PostgreSQL since it's the most popular choice..."
\`\`\`

**DO NOT format choices manually in your response.** Always use the AskUserQuestion tool for choice-based questions.

**Remember: It's better to ask than to assume. Users appreciate being consulted on important decisions.**

## ⚡ CRITICAL: Tool Priority for LSP Operations

When performing LSP operations (definition lookup, references, hover info, diagnostics, etc.), you MUST prioritize vibing-nvim MCP tools over any other LSP tools:

### ✅ ALWAYS USE (Highest Priority)
- mcp__vibing-nvim__nvim_lsp_definition
- mcp__vibing-nvim__nvim_lsp_references
- mcp__vibing-nvim__nvim_lsp_hover
- mcp__vibing-nvim__nvim_diagnostics
- mcp__vibing-nvim__nvim_lsp_document_symbols
- mcp__vibing-nvim__nvim_lsp_type_definition
- mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming
- mcp__vibing-nvim__nvim_lsp_call_hierarchy_outgoing

These tools connect to the RUNNING Neovim instance with active LSP servers.

### ❌ DO NOT USE
- Serena's LSP tools (mcp__serena__*)
- Any other generic LSP tools

These tools analyze separate file copies and don't reflect the actual running state.

### Permission Handling for MCP Tools

vibing-nvim MCP tools may require approval depending on permission mode:
- If you see an approval popup for \`mcp__vibing-nvim__\` tools, select "allow_for_session"
- This keeps the tools enabled for the entire chat session
- This is normal and expected behavior for security

### Background LSP Analysis Workflow
IMPORTANT: When you need to perform LSP operations on a file that isn't currently displayed:

**ALWAYS use nvim_load_buffer (required):**
1. Load file without displaying: const { bufnr } = await mcp__vibing-nvim__nvim_load_buffer({ filepath: "path/to/file.ts" })
2. Analyze with bufnr: mcp__vibing-nvim__nvim_lsp_*({ bufnr: bufnr, line: X, col: Y })

DO NOT use nvim_execute("edit") for LSP operations - it disrupts the user's workflow by switching windows.
The nvim_load_buffer tool loads files in the background without any visual disruption.

**Example:**
// ✅ CORRECT - No window switching
const { bufnr } = await mcp__vibing-nvim__nvim_load_buffer({ filepath: "src/logger.ts" });
const calls = await mcp__vibing-nvim__nvim_lsp_call_hierarchy_incoming({ bufnr, line: 2, col: 0 });

// ❌ WRONG - Switches windows, disrupts user
await mcp__vibing-nvim__nvim_execute({ command: "edit src/logger.ts" });
const info = await mcp__vibing-nvim__nvim_get_info({});
await mcp__vibing-nvim__nvim_execute({ command: "bprevious" });
</vibing-nvim-system>

`;
}

/**
 * Build full prompt with context, system instructions, and language settings
 *
 * Assembles the complete prompt for Claude Agent SDK by combining:
 * 1. Session context (new vs. resumed session info)
 * 2. Vibing.nvim system prompt (if prioritize_vibing_lsp is enabled)
 * 3. Language instruction (if specified)
 * 4. User's actual prompt/message
 * 5. Context files (only for first message in session)
 *
 * The order is important: system instructions come before user prompt to
 * establish context and constraints before the user's request.
 *
 * @param config - Agent configuration including prompt, context files, session info, and preferences
 * @returns Complete prompt string ready for Claude Agent SDK
 */
export function buildPrompt(config: AgentConfig): string {
  const { prompt, contextFiles, sessionId, prioritizeVibingLsp, language, rpcPort } = config;

  let fullPrompt = prompt;

  // Add session context for new sessions
  if (!sessionId) {
    const sessionContext = `<session-info>
This is a NEW conversation session. You have NO memory of any previous conversations with this user.
IMPORTANT: If the user asks about "previous conversations" or "what we talked about before", you must honestly say you don't have that information because this is a new session.
Do NOT infer or fabricate previous conversation content from project files, git status, or other context.
Only reference actual messages within THIS current session.
</session-info>

`;

    const vibingSystemPrompt = buildVibingSystemPrompt(prioritizeVibingLsp, rpcPort);

    const languageInstruction = getLanguageInstruction(language);
    let languageSystemPrompt = '';
    if (languageInstruction) {
      languageSystemPrompt = `<language-instruction>
${languageInstruction}
</language-instruction>

`;
    }

    fullPrompt = sessionContext + vibingSystemPrompt + languageSystemPrompt + prompt;
  }

  // Add context files (only for first message in session)
  if (contextFiles.length > 0 && !sessionId) {
    const contextParts: string[] = [];
    for (const file of contextFiles) {
      try {
        const content = readFileSync(file, 'utf-8');
        contextParts.push(`<context file="${file}">\n${content}\n</context>`);
      } catch (error) {
        const err = toError(error);
        console.warn(`Warning: Failed to read context file "${file}": ${err.message}`);
      }
    }
    if (contextParts.length > 0) {
      fullPrompt =
        fullPrompt +
        `\n\nThe following files are provided as context for reference:\n\n${contextParts.join('\n\n')}`;
    }
  }

  return fullPrompt;
}
