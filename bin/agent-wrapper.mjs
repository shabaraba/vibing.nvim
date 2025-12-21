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
let permissionRules = [];
let mode = null;
let model = null;
let permissionMode = 'acceptEdits';

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
  } else if (!args[i].startsWith('--')) {
    prompt = args[i];
  }
}

if (!prompt) {
  console.error('Usage: agent-wrapper.mjs --prompt <prompt> [--cwd <dir>] [--context <file>...]');
  process.exit(1);
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
  fullPrompt = sessionContext + prompt;
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
  permissionMode: permissionMode,
  // Required when using bypassPermissions
  allowDangerouslySkipPermissions: permissionMode === 'bypassPermissions',
};

// Add allowed tools (auto-allowed without prompting)
if (allowedTools.length > 0) {
  queryOptions.allowedTools = allowedTools;
}

// Add disallowed tools
if (deniedTools.length > 0) {
  queryOptions.disallowedTools = deniedTools;
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
const normalizedAllow = allowedTools.map((t) => t.toLowerCase());
const normalizedDeny = deniedTools.map((t) => t.toLowerCase());

queryOptions.canUseTool = async (toolName, input) => {
  const normalizedToolName = toolName.toLowerCase();

  // Check deny list first
  if (normalizedDeny.includes(normalizedToolName)) {
    return {
      behavior: 'deny',
      message: `Tool ${toolName} is not allowed by configuration`,
    };
  }

  // Check allow list (if specified)
  if (normalizedAllow.length > 0 && !normalizedAllow.includes(normalizedToolName)) {
    return {
      behavior: 'deny',
      message: `Tool ${toolName} is not in the allowed list`,
    };
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

let sessionIdEmitted = false;

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
      }
    }

    // Handle assistant messages (main text responses)
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'text' && block.text) {
          console.log(safeJsonStringify({ type: 'chunk', text: block.text }));
        } else if (block.type === 'tool_use') {
          // Tool use indication
          const toolName = block.name;
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

          // Emit structured tool_use event for file-modifying operations
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
          let resultText = '';
          if (typeof block.content === 'string') {
            resultText = block.content;
          } else if (Array.isArray(block.content)) {
            resultText = block.content.map((c) => c.text || '').join('');
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
