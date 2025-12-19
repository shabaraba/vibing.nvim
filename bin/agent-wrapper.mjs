#!/usr/bin/env node
/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Uses query API for full permission control support
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from '@anthropic-ai/claude-agent-sdk';

const args = process.argv.slice(2);
let prompt = '';
let cwd = process.cwd();
const contextFiles = [];
let sessionId = null;
let allowedTools = [];
let deniedTools = [];
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
        console.log(JSON.stringify({ type: 'session', session_id: message.session_id }));
        sessionIdEmitted = true;
      }
    }

    // Handle assistant messages (main text responses)
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'text' && block.text) {
          console.log(JSON.stringify({ type: 'chunk', text: block.text }));
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
              JSON.stringify({
                type: 'tool_use',
                tool: toolName,
                file_path: toolInput.file_path,
              })
            );
          }

          console.log(
            JSON.stringify({
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
              JSON.stringify({
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

  console.log(JSON.stringify({ type: 'done' }));
} catch (error) {
  console.log(JSON.stringify({ type: 'error', message: error.message || String(error) }));
  process.exit(1);
}
