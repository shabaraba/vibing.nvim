#!/usr/bin/env node
/**
 * Claude Agent SDK wrapper for vibing.nvim
 * Outputs streaming text chunks to stdout as JSON lines
 */

import { query } from "@anthropic-ai/claude-agent-sdk";

const args = process.argv.slice(2);
let prompt = "";
let cwd = process.cwd();
const contextFiles = [];
let sessionId = null;
let allowedTools = [];
let deniedTools = [];
let mode = null;
let model = null;

// Parse arguments
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--cwd" && args[i + 1]) {
    cwd = args[i + 1];
    i++;
  } else if (args[i] === "--context" && args[i + 1]) {
    contextFiles.push(args[i + 1]);
    i++;
  } else if (args[i] === "--session" && args[i + 1]) {
    sessionId = args[i + 1];
    i++;
  } else if (args[i] === "--mode" && args[i + 1]) {
    mode = args[i + 1];
    i++;
  } else if (args[i] === "--model" && args[i + 1]) {
    model = args[i + 1];
    i++;
  } else if (args[i] === "--prompt" && args[i + 1]) {
    prompt = args[i + 1];
    i++;
  } else if (args[i] === "--allow" && args[i + 1]) {
    allowedTools = args[i + 1].split(",").map(t => t.trim()).filter(t => t);
    i++;
  } else if (args[i] === "--deny" && args[i + 1]) {
    deniedTools = args[i + 1].split(",").map(t => t.trim()).filter(t => t);
    i++;
  } else if (!args[i].startsWith("--")) {
    prompt = args[i];
  }
}

if (!prompt) {
  console.error("Usage: agent-wrapper.mjs --prompt <prompt> [--cwd <dir>] [--context <file>...]");
  process.exit(1);
}

// Change to working directory BEFORE reading context files
process.chdir(cwd);

// Build full prompt with context
let fullPrompt = prompt;

// Add context files (only for first message in session)
if (contextFiles.length > 0 && !sessionId) {
  const fs = await import("fs");
  const contextParts = [];
  for (const file of contextFiles) {
    try {
      const content = fs.readFileSync(file, "utf-8");
      contextParts.push(`<context file="${file}">\n${content}\n</context>`);
    } catch (e) {
      // Skip unreadable files
    }
  }
  if (contextParts.length > 0) {
    fullPrompt = `The following files are provided as context for reference:\n\n${contextParts.join("\n\n")}\n\n---\n\nUser request:\n${prompt}`;
  }
}

// Output format: JSON lines for easy parsing
// { "type": "chunk", "text": "..." }
// { "type": "tool_use", "name": "...", "input": "..." }
// { "type": "tool_result", "name": "...", "output": "..." }
// { "type": "done" }
// { "type": "error", "message": "..." }

let lastWasText = false;
let pendingToolUse = null;

// Build query options
const queryOptions = {
  allowedTools: ["Read", "Edit", "Write", "Bash", "Glob", "Grep", "WebSearch", "WebFetch"],
  permissionMode: "default",
  includePartialMessages: true,
};

<<<<<<< HEAD
// Add canUseTool callback for permission control
if (allowedTools.length > 0 || deniedTools.length > 0) {
  // Normalize tool names to lowercase for case-insensitive comparison
  const normalizedAllow = allowedTools.map(t => t.toLowerCase());
  const normalizedDeny = deniedTools.map(t => t.toLowerCase());

  queryOptions.canUseTool = async (toolName, input) => {
    const normalizedToolName = toolName.toLowerCase();

    // Deny list takes precedence
    if (normalizedDeny.includes(normalizedToolName)) {
      return {
        behavior: "deny",
        message: `Tool ${toolName} is not allowed by configuration`,
      };
    }

    // Allow list
    if (normalizedAllow.length > 0 && !normalizedAllow.includes(normalizedToolName)) {
      return {
        behavior: "deny",
        message: `Tool ${toolName} is not in the allowed list`,
      };
    }

    // Allow by default if passed checks
    return {
      behavior: "allow",
      updatedInput: input,
    };
  };
=======
// Add mode if provided
if (mode) {
  queryOptions.mode = mode;
}

// Add model if provided
if (model) {
  queryOptions.model = model;
>>>>>>> 85102f8 (feat: add default mode and model configuration for Agent SDK)
}

// Resume session if provided
if (sessionId) {
  queryOptions.resume = sessionId;
}

try {
  for await (const message of query({
    prompt: fullPrompt,
    options: queryOptions,
  })) {
    // Capture session ID from init message
    if (message.type === "system" && message.subtype === "init" && message.session_id) {
      console.log(JSON.stringify({ type: "session", session_id: message.session_id }));
    }

    if (message.type === "stream_event" && message.event) {
      const event = message.event;

      // content_block_start can indicate tool_use
      if (event.type === "content_block_start" && event.content_block?.type === "tool_use") {
        if (lastWasText) {
          console.log(JSON.stringify({ type: "chunk", text: "\n\n" }));
        }
        pendingToolUse = {
          name: event.content_block.name,
          input: {}
        };
        lastWasText = false;
      }

      // content_block_delta contains incremental text or tool input
      if (event.type === "content_block_delta") {
        if (event.delta?.type === "text_delta") {
          console.log(JSON.stringify({ type: "chunk", text: event.delta.text }));
          lastWasText = true;
        } else if (event.delta?.type === "input_json_delta" && pendingToolUse) {
          // Accumulate tool input JSON
          pendingToolUse.inputJson = (pendingToolUse.inputJson || "") + event.delta.partial_json;
        }
      }

      // content_block_stop - output tool use info
      if (event.type === "content_block_stop" && pendingToolUse) {
        try {
          if (pendingToolUse.inputJson) {
            pendingToolUse.input = JSON.parse(pendingToolUse.inputJson);
          }
        } catch (e) {}

        const toolName = pendingToolUse.name;
        const toolInput = pendingToolUse.input;
        let inputSummary = "";
        if (toolInput.command) {
          inputSummary = toolInput.command.length > 50 ? toolInput.command.substring(0, 50) + "..." : toolInput.command;
        } else if (toolInput.file_path) {
          inputSummary = toolInput.file_path;
        } else if (toolInput.pattern) {
          inputSummary = toolInput.pattern;
        } else if (toolInput.query) {
          inputSummary = toolInput.query;
        }
        console.log(JSON.stringify({
          type: "chunk",
          text: `⏺ ${toolName}(${inputSummary})\n`
        }));
        pendingToolUse = null;
      }
    } else if (message.type === "user" && message.message?.content) {
      // Tool result comes as user message
      for (const block of message.message.content) {
        if (block.type === "tool_result" && block.content) {
          let resultText = "";
          if (typeof block.content === "string") {
            resultText = block.content;
          } else if (Array.isArray(block.content)) {
            resultText = block.content.map(c => c.text || "").join("");
          }
          const preview = resultText.length > 100 ? resultText.substring(0, 100) + "..." : resultText;
          if (preview) {
            console.log(JSON.stringify({
              type: "chunk",
              text: `  ⎿  ${preview.replace(/\n/g, "\n     ")}\n\n`
            }));
          }
        }
      }
    }
    // Skip assistant message - we handle content via stream_event
  }

  console.log(JSON.stringify({ type: "done" }));
} catch (error) {
  console.log(JSON.stringify({ type: "error", message: error.message || String(error) }));
  process.exit(1);
}
