/**
 * Processes Agent SDK response stream and outputs JSON Lines format.
 */

import { safeJsonStringify } from './utils.mjs';
import PatchStorage from './patch-storage.mjs';

function emit(obj) {
  console.log(safeJsonStringify(obj));
}

function extractInputSummary(toolInput) {
  return toolInput.command || toolInput.file_path || toolInput.pattern || toolInput.query || '';
}

function extractResultText(content) {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((c) => c.text || '').join('');
  return '';
}

function formatToolResult(toolName, inputSummary, resultText, displayMode, prefixNewline) {
  let text = prefixNewline ? '\n' : '';
  text += `⏺ ${toolName}(${inputSummary})\n`;

  if (displayMode === 'none' || !resultText) return text;

  const displayText =
    displayMode === 'compact' && resultText.length > 100
      ? resultText.substring(0, 100) + '...'
      : resultText;

  if (displayText) {
    text += `  ⎿  ${displayText.replace(/\n/g, '\n     ')}\n`;
  }

  return text;
}

export async function processStream(resultStream, toolResultDisplay, sessionId, cwd, config) {
  let sessionIdEmitted = false;
  let respondingEmitted = false;
  let lastOutputType = null;
  const processedToolUseIds = new Set();
  const toolUseMap = new Map();
  const toolInputMap = new Map();

  const patchStorage = new PatchStorage();
  if (sessionId) patchStorage.setSessionId(sessionId);
  if (cwd) patchStorage.setCwd(cwd);
  if (config) patchStorage.setSaveConfig(config.saveLocationType, config.saveDir);

  for await (const message of resultStream) {
    if (
      message.type === 'system' &&
      message.subtype === 'init' &&
      message.session_id &&
      !sessionIdEmitted
    ) {
      emit({ type: 'session', session_id: message.session_id });
      sessionIdEmitted = true;
      if (!sessionId) patchStorage.setSessionId(message.session_id);
      patchStorage.takeSnapshot();
      emit({ type: 'status', state: 'thinking' });
    }

    if (message.type === 'assistant' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'text' && block.text) {
          if (!respondingEmitted) {
            emit({ type: 'status', state: 'responding' });
            respondingEmitted = true;
          }
          const text = lastOutputType === 'tool_result' ? '\n' + block.text : block.text;
          emit({ type: 'chunk', text });
          lastOutputType = 'text';
          continue;
        }

        if (block.type === 'tool_use' && !processedToolUseIds.has(block.id)) {
          processedToolUseIds.add(block.id);
          const toolName = block.name;
          const toolInput = block.input || {};
          const inputSummary = extractInputSummary(toolInput);

          toolUseMap.set(block.id, toolName);
          toolInputMap.set(block.id, inputSummary);

          emit({ type: 'status', state: 'tool_use', tool: toolName, input_summary: inputSummary });

          if ((toolName === 'Edit' || toolName === 'Write') && toolInput.file_path) {
            patchStorage.trackFile(toolInput.file_path);
            emit({ type: 'tool_use', tool: toolName, file_path: toolInput.file_path });
          }

          if (toolName === 'Bash' && toolInput.command) {
            emit({ type: 'tool_use', tool: 'Bash', command: toolInput.command });
          }
        }
      }
    }

    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type !== 'tool_result' || !block.content) continue;

        const toolName = toolUseMap.get(block.tool_use_id);
        if (!toolName) continue;

        const resultText = extractResultText(block.content);

        if (toolName === 'mcp__vibing-nvim__nvim_set_buffer') {
          const match = resultText.match(/Buffer updated successfully \(([^)]+)\)/);
          if (match) {
            patchStorage.trackFile(match[1]);
            emit({ type: 'tool_use', tool: 'nvim_set_buffer', file_path: match[1] });
          }
        }

        const inputSummary = toolInputMap.get(block.tool_use_id) || '';
        const toolText = formatToolResult(
          toolName,
          inputSummary,
          resultText,
          toolResultDisplay,
          lastOutputType === 'text'
        );
        emit({ type: 'chunk', text: toolText });
        lastOutputType = 'tool_result';

        toolUseMap.delete(block.tool_use_id);
        toolInputMap.delete(block.tool_use_id);
      }
    }

    if (message.type === 'result') {
      const patchContent = patchStorage.generatePatch();
      if (patchContent) {
        const patchFilename = patchStorage.savePatchToFile(patchContent);
        if (patchFilename) {
          emit({ type: 'patch_saved', filename: patchFilename });
        }
      }
      patchStorage.clear();
    }
  }

  emit({ type: 'done' });
}
