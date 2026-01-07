#!/usr/bin/env node
/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Uses query API for full permission control support
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from '@anthropic-ai/claude-agent-sdk';
import { URL } from 'url';

const args = process.argv.slice(2);
let prompt = '';
let cwd = process.cwd();
const contextFiles = [];
let sessionId = null;
let allowedTools = [];
let deniedTools = [];
let askedTools = [];
let permissionRules = [];
let mode = null;
let model = null;
let permissionMode = 'acceptEdits';
let prioritizeVibingLsp = true; // Default: prioritize vibing-nvim LSP tools
let mcpEnabled = false; // Default: MCP integration disabled
let language = null; // Language code for AI responses (e.g., "ja", "en")
let rpcPort = null; // RPC port of the Neovim instance running this chat

// Parse arguments
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--cwd' && args[i + 1]) {
    cwd = args[i + 1];
    i++;
  } else if (args[i] === '--context' && args[i + 1]) {
    contextFiles.push(args[i + 1]);
    i++;
  } else if (args[i] === '--session' && args[i + 1]) {
    sessionId = args[i + 1];
    i++;
  } else if (args[i] === '--mode' && args[i + 1]) {
    mode = args[i + 1];
    i++;
  } else if (args[i] === '--model' && args[i + 1]) {
    model = args[i + 1];
    i++;
  } else if (args[i] === '--prompt' && args[i + 1]) {
    prompt = args[i + 1];
    i++;
  } else if (args[i] === '--allow' && args[i + 1]) {
    allowedTools = args[i + 1]
      .split(',')
      .map((t) => t.trim())
      .filter((t) => t);
    i++;
  } else if (args[i] === '--deny' && args[i + 1]) {
    deniedTools = args[i + 1]
      .split(',')
      .map((t) => t.trim())
      .filter((t) => t);
    i++;
  } else if (args[i] === '--ask' && args[i + 1]) {
    askedTools = args[i + 1]
      .split(',')
      .map((t) => t.trim())
      .filter((t) => t);
    i++;
  } else if (args[i] === '--permission-mode' && args[i + 1]) {
    permissionMode = args[i + 1];
    i++;
  } else if (args[i] === '--rules' && args[i + 1]) {
    try {
      permissionRules = JSON.parse(args[i + 1]);

      // Validate rule structure
      if (!Array.isArray(permissionRules)) {
        throw new Error('--rules must be an array of rule objects');
      }

      for (let j = 0; j < permissionRules.length; j++) {
        const rule = permissionRules[j];
        if (!rule || typeof rule !== 'object') {
          throw new Error(`Rule at index ${j} must be an object`);
        }

        // Validate required fields
        if (!Array.isArray(rule.tools) || rule.tools.length === 0) {
          throw new Error(`Rule at index ${j} must have a non-empty 'tools' array`);
        }

        if (!rule.action || !['allow', 'deny'].includes(rule.action)) {
          throw new Error(`Rule at index ${j} must have 'action' set to "allow" or "deny"`);
        }

        // Validate optional fields if present
        if (rule.paths !== undefined && !Array.isArray(rule.paths)) {
          throw new Error(`Rule at index ${j}: 'paths' must be an array if specified`);
        }

        if (rule.commands !== undefined && !Array.isArray(rule.commands)) {
          throw new Error(`Rule at index ${j}: 'commands' must be an array if specified`);
        }

        if (rule.patterns !== undefined && !Array.isArray(rule.patterns)) {
          throw new Error(`Rule at index ${j}: 'patterns' must be an array if specified`);
        }

        if (rule.domains !== undefined && !Array.isArray(rule.domains)) {
          throw new Error(`Rule at index ${j}: 'domains' must be an array if specified`);
        }

        if (rule.message !== undefined && typeof rule.message !== 'string') {
          throw new Error(`Rule at index ${j}: 'message' must be a string if specified`);
        }
      }
    } catch (e) {
      console.error('Failed to parse --rules JSON:', e.message);
      process.exit(1);
    }
    i++;
  } else if (args[i] === '--prioritize-vibing-lsp' && args[i + 1]) {
    prioritizeVibingLsp = args[i + 1] === 'true';
    i++;
  } else if (args[i] === '--mcp-enabled' && args[i + 1]) {
    mcpEnabled = args[i + 1] === 'true';
    i++;
  } else if (args[i] === '--language' && args[i + 1]) {
    language = args[i + 1];
    i++;
  } else if (args[i] === '--rpc-port' && args[i + 1]) {
    rpcPort = parseInt(args[i + 1], 10);
    i++;
  } else if (!args[i].startsWith('--')) {
    prompt = args[i];
  }
}

if (!prompt) {
  console.error('Usage: agent-wrapper.mjs --prompt <prompt> [--cwd <dir>] [--context <file>...]');
  process.exit(1);
}

// Language code to name mapping
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

// Generate language instruction for AI responses
function getLanguageInstruction(langCode) {
  if (!langCode) {
    return '';
  }

  const langName = languageNames[langCode];
  if (!langName) {
    console.warn(`[vibing.nvim] Unknown language code: ${langCode}, falling back to default`);
    return '';
  }

  // Always generate instruction for consistency, even for English
  return `Please respond to the user in ${langName}.`;
}

// Build full prompt with context
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

  let vibingSystemPrompt = '';
  if (prioritizeVibingLsp) {
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

    vibingSystemPrompt = `<vibing-nvim-system>
IMPORTANT: You are running inside vibing.nvim, a Neovim plugin with Claude Code integration.${rpcPortInfo}

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

  // Add language instruction for AI responses (only for new sessions)
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
  const fs = await import('fs');
  const contextParts = [];
  for (const file of contextFiles) {
    try {
      const content = fs.readFileSync(file, 'utf-8');
      contextParts.push(`<context file="${file}">\n${content}\n</context>`);
    } catch {
      // Skip unreadable files
    }
  }
  if (contextParts.length > 0) {
    fullPrompt =
      fullPrompt +
      `\n\nThe following files are provided as context for reference:\n\n${contextParts.join('\n\n')}`;
  }
}

// Output format: JSON lines for easy parsing
// { "type": "chunk", "text": "..." }
// { "type": "session", "session_id": "..." }
// { "type": "done" }
// { "type": "error", "message": "..." }

// Build query options
const queryOptions = {
  cwd: cwd,
  // CRITICAL: Do NOT set permissionMode (even to 'default')
  // Setting ANY permissionMode value causes SDK to bypass canUseTool callback
  // Leave it undefined to ensure canUseTool is called for all tools
  // ...(permissionMode === 'bypassPermissions' ? { permissionMode: permissionMode } : {}),
  // Required when using bypassPermissions
  allowDangerouslySkipPermissions: permissionMode === 'bypassPermissions',
  // Load user and project settings (~/.claude.json and .claude/)
  // This allows vibing.nvim to use:
  // - User's custom MCP servers (including vibing-nvim MCP registered via ~/.claude.json)
  // - Project slash commands (.claude/commands/)
  // - Project skills (.claude/skills/)
  // - User's global settings and subagents
  settingSources: ['user', 'project'],
};

// Permission architecture notes:
// - disallowedTools: SDK built-in feature that removes tools from model context entirely
// - allowedTools: SDK built-in feature that restricts available tools (triggers canUseTool for others)
// - canUseTool: Custom callback for fine-grained permission logic (deny > ask > allow)
//
// Strategy:
// 1. Set allowedTools = allowedTools + askedTools (tools that CAN be used, subject to approval)
// 2. Set disallowedTools = deniedTools (tools that CANNOT be used at all)
// 3. Use canUseTool to differentiate between auto-approve (allow) and ask-first (ask)

// Set disallowedTools to completely block denied tools (removes from model context)
if (deniedTools.length > 0) {
  queryOptions.disallowedTools = deniedTools;
}

// CRITICAL FINDING: SDK behavior differs from documentation
// - If allowedTools is NOT set: SDK auto-approves ALL tools, never calls canUseTool
// - If allowedTools IS set: SDK calls canUseTool for tools NOT in allowedTools
//
// Solution: Set allowedTools to auto-approved tools ONLY
// askedTools will NOT be in allowedTools, forcing SDK to call canUseTool for them
if (allowedTools.length > 0) {
  queryOptions.allowedTools = allowedTools;
}

// Helper function: safe JSON stringify with error handling
function safeJsonStringify(obj) {
  try {
    return JSON.stringify(obj);
  } catch (error) {
    // Fallback for circular references or other serialization errors
    try {
      return JSON.stringify({
        type: 'error',
        message: 'Failed to serialize output: ' + String(error),
      });
    } catch {
      return '{"type":"error","message":"Critical serialization failure"}';
    }
  }
}

// Helper function: simple glob pattern matching (basic implementation)
function matchGlob(pattern, str) {
  // Validate input to prevent ReDoS
  if (typeof pattern !== 'string' || typeof str !== 'string') {
    return false;
  }

  // Limit pattern length to prevent ReDoS attacks
  if (pattern.length > 1000) {
    return false;
  }

  try {
    // Escape all regex special chars except * and ?
    const escaped = pattern.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    // Replace glob wildcards with regex equivalents
    // Use non-greedy matching to reduce ReDoS risk
    const regexPattern = escaped.replace(/\*/g, '.*?').replace(/\?/g, '.');
    const regex = new RegExp(`^${regexPattern}$`);
    return regex.test(str);
  } catch {
    // Return false if regex compilation fails
    return false;
  }
}

// Helper function: check if rule matches tool and input
function checkRule(rule, toolName, input) {
  // Check if rule applies to this tool
  if (!rule.tools || !rule.tools.includes(toolName)) {
    return null; // Rule doesn't apply
  }

  // Check file path patterns
  if (rule.paths && rule.paths.length > 0 && input.file_path) {
    const pathMatches = rule.paths.some((pattern) => matchGlob(pattern, input.file_path));
    if (pathMatches) {
      return rule.action; // "allow" or "deny"
    }
    // If paths are specified but don't match, rule doesn't apply
    return null;
  }

  // Check Bash command patterns
  if (toolName === 'Bash' && input.command) {
    const commandParts = input.command.trim().split(/\s+/);
    const baseCommand = commandParts[0];

    // Check allowed commands list (typically for allow rules)
    if (rule.commands && rule.commands.length > 0) {
      const commandMatches = rule.commands.includes(baseCommand);
      if (commandMatches) {
        return rule.action;
      }
    }

    // Check denied patterns (regex) - typically for deny rules
    if (rule.patterns && rule.patterns.length > 0) {
      const patternMatches = rule.patterns.some((pattern) => {
        try {
          // Validate pattern to prevent ReDoS
          if (typeof pattern !== 'string' || pattern.length > 500) {
            return false;
          }
          const regex = new RegExp(pattern);
          return regex.test(input.command);
        } catch {
          return false;
        }
      });
      if (patternMatches) {
        return rule.action;
      }
    }

    // If both commands and patterns are specified but neither match, rule doesn't apply
    if (
      (rule.commands && rule.commands.length > 0) ||
      (rule.patterns && rule.patterns.length > 0)
    ) {
      return null;
    }
  }

  // Check URL/domain patterns
  if (toolName === 'WebFetch' && input.url) {
    if (rule.domains && rule.domains.length > 0) {
      try {
        const url = new URL(input.url);
        const hostname = url.hostname;
        const domainMatches = rule.domains.some((domain) => matchGlob(domain, hostname));
        if (domainMatches) {
          return rule.action;
        }
        return null;
      } catch {
        // Invalid URL, ignore rule
        return null;
      }
    }
  }

  // Rule doesn't have applicable conditions
  return null;
}

// Add custom canUseTool callback for additional control
// Helper: Parse tool permission string like "Tool(pattern)" -> { toolName, ruleContent, type }
// Follows Agent SDK PermissionRuleValue structure: { toolName: string, ruleContent?: string }
function parseToolPattern(toolStr) {
  // Match granular pattern: Tool(ruleContent)
  const granularMatch = toolStr.match(/^([a-z]+)\((.+)\)$/i);
  if (granularMatch) {
    const toolName = granularMatch[1].toLowerCase();
    const ruleContent = granularMatch[2];

    // Determine pattern type based on tool name
    if (toolName === 'bash') {
      // Bash: wildcard (npm:*) or exact (npm install)
      const isWildcard = ruleContent.match(/^([^:]+):\*$/);
      return {
        toolName: 'bash',
        ruleContent: ruleContent.toLowerCase(),
        type: isWildcard ? 'bash_wildcard' : 'bash_exact',
      };
    } else if (['read', 'write', 'edit'].includes(toolName)) {
      // File tools: glob patterns (src/**/*.ts)
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'file_glob',
      };
    } else if (['webfetch', 'websearch'].includes(toolName)) {
      // Web tools: domain patterns (github.com, *.npmjs.com)
      return {
        toolName: toolName,
        ruleContent: ruleContent.toLowerCase(),
        type: 'domain_pattern',
      };
    } else if (['glob', 'grep'].includes(toolName)) {
      // Search tools: patterns
      return {
        toolName: toolName,
        ruleContent: ruleContent,
        type: 'search_pattern',
      };
    }

    // Unknown tool with pattern
    return {
      toolName: toolName,
      ruleContent: ruleContent,
      type: 'unknown_pattern',
    };
  }

  // Simple tool name without pattern
  return { toolName: toolStr.toLowerCase(), ruleContent: null, type: 'tool_name' };
}

// Helper: Match Bash command against permission pattern
function matchesBashPattern(command, ruleContent, type) {
  const cmd = command.trim().toLowerCase();
  const rule = ruleContent.toLowerCase();

  if (type === 'bash_wildcard') {
    // Extract base command from pattern: "npm:*" -> "npm"
    const basePattern = rule.split(':')[0];
    const cmdParts = cmd.split(/\s+/);
    return cmdParts[0] === basePattern;
  } else {
    // Exact match: "npm install" matches "npm install" or "npm install --save"
    return cmd === rule || cmd.startsWith(rule + ' ');
  }
}

// Helper: Match file path against glob pattern
function matchesFileGlob(filePath, globPattern) {
  return matchGlob(globPattern, filePath);
}

// Helper: Match URL domain against pattern
// Examples:
// - "github.com" matches "https://github.com/..."
// - "*.npmjs.com" matches "https://registry.npmjs.com/..."
function matchesDomainPattern(url, domainPattern) {
  try {
    const urlObj = new URL(url);
    const hostname = urlObj.hostname.toLowerCase();
    const pattern = domainPattern.toLowerCase();

    // Exact match
    if (hostname === pattern) {
      return true;
    }

    // Wildcard match: *.example.com
    if (pattern.startsWith('*.')) {
      const baseDomain = pattern.slice(2); // Remove "*."
      return hostname === baseDomain || hostname.endsWith('.' + baseDomain);
    }

    return false;
  } catch {
    return false;
  }
}

// Helper: Check if tool matches permission string (unified for all tools)
function matchesPermission(toolName, input, permissionStr) {
  try {
    const parsed = parseToolPattern(permissionStr);

    // Simple tool name match (no pattern)
    if (parsed.type === 'tool_name') {
      const permToolName = parsed.toolName;
      const actualToolName = toolName.toLowerCase();

      // Check for wildcard in tool name (e.g., "mcp__vibing-nvim__*")
      if (permToolName.endsWith('*')) {
        const prefix = permToolName.slice(0, -1); // Remove trailing '*'
        return actualToolName.startsWith(prefix);
      }

      // Exact match
      return actualToolName === permToolName;
    }

    // Tool name must match
    if (toolName.toLowerCase() !== parsed.toolName) {
      return false;
    }

    // Pattern-based matching
    switch (parsed.type) {
      case 'bash_wildcard':
      case 'bash_exact':
        return input.command
          ? matchesBashPattern(input.command, parsed.ruleContent, parsed.type)
          : false;

      case 'file_glob':
        return input.file_path ? matchesFileGlob(input.file_path, parsed.ruleContent) : false;

      case 'domain_pattern':
        return input.url ? matchesDomainPattern(input.url, parsed.ruleContent) : false;

      case 'search_pattern':
        // For Glob/Grep, pattern in ruleContent should match tool's pattern parameter
        // This is a simple equality check for now
        return input.pattern ? input.pattern === parsed.ruleContent : false;

      default:
        // Unknown pattern type - deny for safety
        return false;
    }
  } catch (error) {
    const errorMsg = `Permission matching failed for ${toolName} with pattern ${permissionStr}: ${error.message}`;
    console.error('[ERROR]', errorMsg, error.stack);

    // Notify user via JSON Lines protocol (displayed in chat)
    console.log(
      JSON.stringify({
        type: 'error',
        message: errorMsg,
      })
    );

    // On error, deny for safety
    return false;
  }
}

queryOptions.canUseTool = async (toolName, input) => {
  try {
    // Note: deniedTools are handled by queryOptions.disallowedTools (SDK built-in)
    // They are already removed from model's context, so won't reach this callback.

    // Implement acceptEdits mode: auto-approve Edit/Write tools
    if (permissionMode === 'acceptEdits' && (toolName === 'Edit' || toolName === 'Write')) {
      return { behavior: 'allow', updatedInput: input };
    }

    // Special handling for vibing-nvim internal MCP tools
    if (toolName.startsWith('mcp__vibing-nvim__')) {
      if (mcpEnabled) {
        return { behavior: 'allow', updatedInput: input };
      } else {
        return {
          behavior: 'deny',
          message:
            'vibing.nvim MCP integration is disabled. Enable it in config: mcp.enabled = true',
        };
      }
    }

    // Check ask list (first priority - but allow list can override)
    for (const askedTool of askedTools) {
      const askMatches = matchesPermission(toolName, input, askedTool);

      if (askMatches) {
        // But check if it's also in the allow list (allow overrides ask)
        let allowedByAllowList = false;

        for (const allowedTool of allowedTools) {
          const matches = matchesPermission(toolName, input, allowedTool);
          if (matches) {
            allowedByAllowList = true;
            break;
          }
        }

        if (!allowedByAllowList) {
          // Tool is in ask list and NOT in allow list
          // Issue #29 workaround: In resume sessions, Agent SDK bypasses canUseTool
          // So we must deny (not ask) to prevent unauthorized execution
          if (sessionId) {
            // Resume session: deny to prevent bypass (Issue #29)
            return {
              behavior: 'deny',
              message: `Tool ${toolName} requires user approval before use. Add it to the allow list with /allow ${askedTool} to enable in resume sessions.`,
            };
          } else {
            // New session: ask for user confirmation (normal behavior)
            return {
              behavior: 'ask',
              updatedInput: input,
            };
          }
        }
        // If allowed by allow list, auto-approve immediately (allow overrides ask)
        return {
          behavior: 'allow',
          updatedInput: input,
        };
      }
    }

    // Check allow list (if specified, with pattern support)
    if (allowedTools.length > 0) {
      let allowed = false;
      for (const allowedTool of allowedTools) {
        if (matchesPermission(toolName, input, allowedTool)) {
          allowed = true;
          break;
        }
      }
      if (!allowed) {
        // Generate context-aware error message based on tool type
        const toolLower = toolName.toLowerCase();
        const toolPatterns = allowedTools.filter((t) =>
          t.toLowerCase().startsWith(toolLower + '(')
        );

        let message = `Tool ${toolName} is not in the allowed list`;

        if (toolPatterns.length > 0) {
          // User has granular patterns for this tool - provide specific feedback
          const patterns = toolPatterns.map((p) => `'${p}'`).join(', ');

          if (toolLower === 'bash' && input.command) {
            message = `Bash command '${input.command}' does not match any allowed patterns. Allowed: ${patterns}`;
          } else if (['read', 'write', 'edit'].includes(toolLower) && input.file_path) {
            message = `${toolName} access to '${input.file_path}' does not match any allowed patterns. Allowed: ${patterns}`;
          } else if (['webfetch', 'websearch'].includes(toolLower) && input.url) {
            message = `${toolName} access to '${input.url}' does not match any allowed patterns. Allowed: ${patterns}`;
          } else if (['glob', 'grep'].includes(toolLower) && input.pattern) {
            message = `${toolName} pattern '${input.pattern}' does not match any allowed patterns. Allowed: ${patterns}`;
          }
        }

        return {
          behavior: 'deny',
          message: message,
        };
      }
    }

    // Check granular permission rules
    if (permissionRules && permissionRules.length > 0) {
      for (const rule of permissionRules) {
        const ruleResult = checkRule(rule, toolName, input);
        if (ruleResult === 'deny') {
          return {
            behavior: 'deny',
            message: rule.message || `Tool ${toolName} is denied by permission rule`,
          };
        }
        // Note: "allow" from rule doesn't override deny list
        // Rules are additional constraints, not overrides
      }
    }

    // Allow the tool
    return {
      behavior: 'allow',
      updatedInput: input,
    };
  } catch (error) {
    console.error('[ERROR] canUseTool failed:', error.message, error.stack);
    console.error('[ERROR] toolName:', toolName, 'input:', JSON.stringify(input));

    // Distinguish between implementation bugs and runtime errors
    if (error instanceof TypeError || error instanceof ReferenceError) {
      // Implementation bugs should fail fast for debugging
      throw error;
    }

    // For other errors, deny for safety but notify user
    return {
      behavior: 'deny',
      message: `Permission check failed due to internal error: ${error.message}. Please report this issue if it persists.`,
    };
  }
};

// Add mode if provided (code, plan, auto, etc.)
if (mode) {
  queryOptions.mode = mode;
}

// Add model if provided
if (model) {
  queryOptions.model = model;
}

// Add session resume if provided
if (sessionId) {
  queryOptions.resume = sessionId;
}

// Add AskUserQuestion callback
queryOptions.askFollowupQuestion = async (input) => {
  // Convert questions to natural language format for chat buffer
  let message = '';
  for (const q of input.questions) {
    message += `${q.question}\n\n`;
    for (const opt of q.options) {
      message += `- ${opt.label}\n`;
      if (opt.description) {
        message += `  ${opt.description}\n`;
      }
    }
    message += `\n`;
  }
  message += `質問に回答し終えたら\`<CR>\`で送信してください。`;

  // Send ask_user_question event to Lua
  console.log(
    safeJsonStringify({
      type: 'ask_user_question',
      questions: input.questions,
      message: message,
    })
  );

  // Wait for user's answer from Lua (via stdin)
  return new Promise((resolve) => {
    pendingAskUserQuestion = input.questions;
    askUserQuestionResolver = resolve;
  });
};

let sessionIdEmitted = false;
let respondingEmitted = false;
const processedToolUseIds = new Set(); // Track processed tool_use IDs to prevent duplicates
const toolUseMap = new Map(); // Map tool_use_id to tool_name for tracking MCP tool results

// AskUserQuestion support
let pendingAskUserQuestion = null; // Current pending question
let askUserQuestionResolver = null; // Promise resolver for current question

// Setup stdin listener for receiving answers from Lua
if (process.stdin.isTTY === false) {
  let stdinBuffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (data) => {
    stdinBuffer += data;
    // Process complete JSON messages (newline-delimited)
    while (true) {
      const newlinePos = stdinBuffer.indexOf('\n');
      if (newlinePos === -1) break;

      const line = stdinBuffer.slice(0, newlinePos);
      stdinBuffer = stdinBuffer.slice(newlinePos + 1);

      if (line.trim()) {
        try {
          const msg = JSON.parse(line);
          if (msg.type === 'ask_user_question_response' && msg.answers) {
            // Lua sent the user's answer
            if (askUserQuestionResolver && pendingAskUserQuestion) {
              askUserQuestionResolver({
                questions: pendingAskUserQuestion,
                answers: msg.answers,
              });
              askUserQuestionResolver = null;
              pendingAskUserQuestion = null;
            }
          }
        } catch (e) {
          console.error('[ERROR] Failed to parse stdin JSON:', e.message);
        }
      }
    }
  });
}

try {
  // Create query with all options
  const result = query({
    prompt: fullPrompt,
    options: queryOptions,
  });

  // Process the response stream
  for await (const message of result) {
    // Emit session ID once from init message
    if (message.type === 'system' && message.subtype === 'init' && message.session_id) {
      if (!sessionIdEmitted) {
        console.log(safeJsonStringify({ type: 'session', session_id: message.session_id }));
        sessionIdEmitted = true;
        // Emit thinking status after session initialization
        console.log(safeJsonStringify({ type: 'status', state: 'thinking' }));
      }
    }

    // Handle assistant messages (main text responses)
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'text' && block.text) {
          // Emit responding status before first text chunk
          if (!respondingEmitted) {
            console.log(safeJsonStringify({ type: 'status', state: 'responding' }));
            respondingEmitted = true;
          }
          console.log(safeJsonStringify({ type: 'chunk', text: block.text }));
        } else if (block.type === 'tool_use') {
          // Check if this tool_use has already been processed
          const toolUseId = block.id;
          if (processedToolUseIds.has(toolUseId)) {
            continue; // Skip duplicate tool_use
          }
          processedToolUseIds.add(toolUseId);

          // Tool use indication
          const toolName = block.name;

          // Store tool_use_id -> tool_name mapping for later result tracking
          toolUseMap.set(toolUseId, toolName);
          let inputSummary = '';
          const toolInput = block.input || {};
          if (toolInput.command) {
            inputSummary =
              toolInput.command.length > 50
                ? toolInput.command.substring(0, 50) + '...'
                : toolInput.command;
          } else if (toolInput.file_path) {
            inputSummary = toolInput.file_path;
          } else if (toolInput.pattern) {
            inputSummary = toolInput.pattern;
          } else if (toolInput.query) {
            inputSummary = toolInput.query;
          }

          // Emit status message for ALL tools
          console.log(
            safeJsonStringify({
              type: 'status',
              state: 'tool_use',
              tool: toolName,
              input_summary: inputSummary,
            })
          );

          // Emit structured tool_use event for file-modifying operations (backward compatibility)
          if ((toolName === 'Edit' || toolName === 'Write') && toolInput.file_path) {
            console.log(
              safeJsonStringify({
                type: 'tool_use',
                tool: toolName,
                file_path: toolInput.file_path,
              })
            );
          }

          console.log(
            safeJsonStringify({
              type: 'chunk',
              text: `\n⏺ ${toolName}(${inputSummary})\n`,
            })
          );
        }
      }
    }

    // Handle tool results (user messages contain tool_result)
    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_result' && block.content) {
          // Get tool name from mapping
          const toolUseId = block.tool_use_id;
          const toolName = toolUseMap.get(toolUseId);

          let resultText = '';
          if (typeof block.content === 'string') {
            resultText = block.content;
          } else if (Array.isArray(block.content)) {
            resultText = block.content.map((c) => c.text || '').join('');
          }

          // Track vibing-nvim MCP tool modifications
          if (toolName === 'mcp__vibing-nvim__nvim_set_buffer') {
            // Extract filename from result text
            if (resultText) {
              // Use [^)]+ to match non-closing-paren chars, handling filenames with parentheses
              const match = resultText.match(/Buffer updated successfully \(([^)]+)\)/);
              if (match) {
                const filename = match[1];
                console.log(
                  safeJsonStringify({
                    type: 'tool_use',
                    tool: 'nvim_set_buffer',
                    file_path: filename,
                  })
                );
              }
            }
          }

          const preview =
            resultText.length > 100 ? resultText.substring(0, 100) + '...' : resultText;
          if (preview) {
            console.log(
              safeJsonStringify({
                type: 'chunk',
                text: `  ⎿  ${preview.replace(/\n/g, '\n     ')}\n\n`,
              })
            );
          }
        }
      }
    }

    // Handle result message
    if (message.type === 'result') {
      // Result processing complete
    }
  }

  console.log(safeJsonStringify({ type: 'done' }));
} catch (error) {
  console.log(safeJsonStringify({ type: 'error', message: error.message || String(error) }));
  process.exit(1);
}
