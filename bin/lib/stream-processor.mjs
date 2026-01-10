/**
 * Stream processor for Agent SDK responses
 * Handles streaming messages and outputs JSON Lines format
 */

import { safeJsonStringify } from './utils.mjs';
import PatchStorage from './patch-storage.mjs';

/**
 * Process Agent SDK response stream
 * @param {AsyncIterable} resultStream - Agent SDK result stream
 * @param {string} toolResultDisplay - Display mode for tool results ("none" | "compact" | "full")
 * @param {string} sessionId - Session ID for patch storage
 * @param {string} cwd - Current working directory
 * @param {Object} config - Configuration object with save location settings
 * @returns {Promise<void>}
 */
export async function processStream(resultStream, toolResultDisplay, sessionId, cwd, config) {
  let sessionIdEmitted = false;
  let respondingEmitted = false;
  const processedToolUseIds = new Set();
  const toolUseMap = new Map();
  const toolInputMap = new Map();
  let lastOutputType = null;

  const patchStorage = new PatchStorage();
  if (sessionId) patchStorage.setSessionId(sessionId);
  if (cwd) patchStorage.setCwd(cwd);
  if (config) patchStorage.setSaveConfig(config.saveLocationType, config.saveDir);

  for await (const message of resultStream) {
    // Emit session ID once from init message
    if (message.type === 'system' && message.subtype === 'init' && message.session_id) {
      if (!sessionIdEmitted) {
        console.log(safeJsonStringify({ type: 'session', session_id: message.session_id }));
        sessionIdEmitted = true;
        if (!sessionId) patchStorage.setSessionId(message.session_id);

        // Take git snapshot at session start (git add -A)
        patchStorage.takeSnapshot();

        console.log(safeJsonStringify({ type: 'status', state: 'thinking' }));
      }
    }

    // Handle assistant messages (main text responses)
    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'text' && block.text) {
          if (!respondingEmitted) {
            console.log(safeJsonStringify({ type: 'status', state: 'responding' }));
            respondingEmitted = true;
          }
          let textToEmit = block.text;
          if (lastOutputType === 'tool_result') {
            textToEmit = '\n' + textToEmit;
          }
          console.log(safeJsonStringify({ type: 'chunk', text: textToEmit }));
          lastOutputType = 'text';
        } else if (block.type === 'tool_use') {
          const toolUseId = block.id;
          if (processedToolUseIds.has(toolUseId)) {
            continue;
          }
          processedToolUseIds.add(toolUseId);

          const toolName = block.name;
          toolUseMap.set(toolUseId, toolName);

          let inputSummary = '';
          const toolInput = block.input || {};
          if (toolInput.command) {
            inputSummary = toolInput.command;
          } else if (toolInput.file_path) {
            inputSummary = toolInput.file_path;
          } else if (toolInput.pattern) {
            inputSummary = toolInput.pattern;
          } else if (toolInput.query) {
            inputSummary = toolInput.query;
          }

          toolInputMap.set(toolUseId, inputSummary);

          console.log(
            safeJsonStringify({
              type: 'status',
              state: 'tool_use',
              tool: toolName,
              input_summary: inputSummary,
            })
          );

          // Emit tool_use event for Edit/Write tools and track file
          if ((toolName === 'Edit' || toolName === 'Write') && toolInput.file_path) {
            patchStorage.trackFile(toolInput.file_path);
            console.log(
              safeJsonStringify({
                type: 'tool_use',
                tool: toolName,
                file_path: toolInput.file_path,
              })
            );
          }

          if (toolName === 'Bash' && toolInput.command) {
            console.log(
              safeJsonStringify({
                type: 'tool_use',
                tool: 'Bash',
                command: toolInput.command,
              })
            );
          }
        }
      }
    }

    // Handle tool results (user messages contain tool_result)
    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_result' && block.content) {
          const toolUseId = block.tool_use_id;
          const toolName = toolUseMap.get(toolUseId);

          if (!toolName) {
            // Skip tool results for unknown tool_use IDs (e.g., from resumed sessions)
            continue;
          }

          let resultText = '';
          if (typeof block.content === 'string') {
            resultText = block.content;
          } else if (Array.isArray(block.content)) {
            resultText = block.content.map((c) => c.text || '').join('');
          }

          // Track nvim_set_buffer file modifications
          if (toolName === 'mcp__vibing-nvim__nvim_set_buffer') {
            if (resultText) {
              const match = resultText.match(/Buffer updated successfully \(([^)]+)\)/);
              if (match) {
                const filename = match[1];
                patchStorage.trackFile(filename);
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

          const inputSummary = toolInputMap.get(toolUseId) || '';

          let toolText = `⏺ ${toolName}(${inputSummary})\n`;
          if (lastOutputType === 'text') {
            toolText = '\n' + toolText;
          }

          if (toolResultDisplay !== 'none') {
            let displayText = '';
            if (toolResultDisplay === 'compact') {
              displayText =
                resultText.length > 100 ? resultText.substring(0, 100) + '...' : resultText;
            } else if (toolResultDisplay === 'full') {
              displayText = resultText;
            }

            if (displayText) {
              toolText += `  ⎿  ${displayText.replace(/\n/g, '\n     ')}\n`;
            }
          }

          console.log(
            safeJsonStringify({
              type: 'chunk',
              text: toolText,
            })
          );
          lastOutputType = 'tool_result';

          toolUseMap.delete(toolUseId);
          toolInputMap.delete(toolUseId);
        }
      }
    }

    // Handle result message - generate and save patch
    if (message.type === 'result') {
      const patchContent = await patchStorage.generateSessionPatch();
      if (patchContent) {
        const patchFilename = patchStorage.savePatchToFile(patchContent);
        if (patchFilename) {
          console.log(
            safeJsonStringify({
              type: 'patch_saved',
              filename: patchFilename,
            })
          );
        }
      }

      // Clear session state
      patchStorage.clear();
    }
  }

  console.log(safeJsonStringify({ type: 'done' }));
}
