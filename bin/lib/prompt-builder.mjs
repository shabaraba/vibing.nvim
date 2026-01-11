/**
 * Prompt builder for agent-wrapper
 * Constructs full prompt with context, system instructions, and language settings
 */

import { readFileSync } from 'fs';

const languageNames = {
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
 * @param {string} langCode - Language code (e.g., "ja", "en")
 * @returns {string} Language instruction text
 */
function getLanguageInstruction(langCode) {
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
 * @param {boolean} prioritizeVibingLsp - Whether to prioritize vibing-nvim LSP tools
 * @param {number|null} rpcPort - RPC port of the Neovim instance
 * @returns {string} System prompt text
 */
function buildVibingSystemPrompt(prioritizeVibingLsp, rpcPort) {
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

## Asking Questions with Choices

**CRITICAL GUIDELINE: When uncertain about implementation details, ALWAYS ask the user first using the AskUserQuestion tool instead of making assumptions.**

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
   - Single-select questions appear as numbered lists (1. 2. 3.)
   - Multi-select questions appear as bullet lists (- - -)
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

## Tool Priority for LSP Operations

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
 * @param {Object} config - Configuration object
 * @returns {string} Full prompt text
 */
export function buildPrompt(config) {
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
    const contextParts = [];
    for (const file of contextFiles) {
      try {
        const content = readFileSync(file, 'utf-8');
        contextParts.push(`<context file="${file}">\n${content}\n</context>`);
      } catch (error) {
        console.warn(`Warning: Failed to read context file "${file}": ${error.message}`);
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
