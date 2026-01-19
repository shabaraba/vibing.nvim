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
You are running inside vibing.nvim, a Neovim plugin with Claude Code integration.${rpcPortInfo}

Key capabilities:
- \`:VibingChatWorktree <branch>\` - Create git worktree with auto-setup (preferred over manual \`git worktree\`)
- \`mcp__vibing-nvim__nvim_lsp_*\` - LSP operations on running Neovim instance (preferred over Serena)
- \`mcp__vibing-nvim__nvim_*\` - Buffer/window operations
- \`AskUserQuestion\` - Ask clarifying questions when uncertain (use proactively)

For command details or usage examples, ask the user.
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
