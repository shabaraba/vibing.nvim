/**
 * Processes Agent SDK response stream and outputs JSON Lines format.
 */

import { safeJsonStringify } from './utils.js';
import PatchStorage from './patch-storage.js';
import { detectVcsOperation } from './vcs-detector.js';
import type { AgentConfig } from '../types.js';

function emit(obj: Record<string, unknown>): void {
  console.log(safeJsonStringify(obj));
}

function extractInputSummary(toolName: string, toolInput: Record<string, unknown>): string {
  // For Task tool, show subagent_type
  if (toolName === 'Task' && toolInput.subagent_type) {
    return toolInput.subagent_type as string;
  }

  return (
    (toolInput.command as string) ||
    (toolInput.file_path as string) ||
    (toolInput.pattern as string) ||
    (toolInput.query as string) ||
    ''
  );
}

interface ContentBlock {
  type?: string;
  text?: string;
}

function extractResultText(content: string | ContentBlock[]): string {
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) return content.map((c) => c.text || '').join('');
  return '';
}

interface TodoItem {
  content: string;
  activeForm: string;
  status: 'pending' | 'in_progress' | 'completed';
}

function formatTodoWriteResult(resultText: string): string {
  try {
    const result = JSON.parse(resultText);
    if (!result.todos || !Array.isArray(result.todos)) {
      return '';
    }

    const todos = result.todos as TodoItem[];
    const lines: string[] = [];

    for (const todo of todos) {
      let emoji = '⏳';
      if (todo.status === 'completed') {
        emoji = '✅';
      } else if (todo.status === 'in_progress') {
        emoji = '🔄';
      }

      const displayText = todo.status === 'in_progress' ? todo.activeForm : todo.content;
      lines.push(`  ${emoji} ${displayText}`);
    }

    return '\n' + lines.join('\n') + '\n';
  } catch {
    return '';
  }
}

function formatToolResult(
  toolName: string,
  inputSummary: string,
  resultText: string,
  displayMode: 'none' | 'compact' | 'full',
  prefixNewline: boolean
): string {
  let text = prefixNewline ? '\n' : '';
  text += `⏺ ${toolName}(${inputSummary})\n`;

  // TodoWriteは設定に関わらず常に全内容を整形して表示
  if (toolName === 'TodoWrite' && resultText) {
    const formattedTodos = formatTodoWriteResult(resultText);
    if (formattedTodos) {
      text += formattedTodos;
    }
    return text;
  }

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

export async function processStream(
  resultStream: AsyncIterable<any>,
  toolResultDisplay: 'none' | 'compact' | 'full',
  sessionId: string | null,
  cwd: string,
  config: AgentConfig
): Promise<void> {
  let sessionIdEmitted = false;
  let respondingEmitted = false;
  let lastOutputType: 'text' | 'tool_result' | null = null;
  const processedToolUseIds = new Set<string>();
  const toolUseMap = new Map<string, string>();
  const toolInputMap = new Map<string, string>();

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
        } else if (block.type === 'tool_use' && !processedToolUseIds.has(block.id)) {
          processedToolUseIds.add(block.id);
          const toolName = block.name;
          const toolInput = block.input || {};
          const inputSummary = extractInputSummary(toolName, toolInput);

          toolUseMap.set(block.id, toolName);
          toolInputMap.set(block.id, inputSummary);

          emit({ type: 'status', state: 'tool_use', tool: toolName, input_summary: inputSummary });

          if (toolName === 'Bash' && toolInput.command) {
            emit({ type: 'tool_use', tool: 'Bash', command: toolInput.command });

            // VCS operation detection for mote integration
            const vcsOp = detectVcsOperation(toolInput.command as string);
            if (vcsOp) {
              emit({ type: 'vcs_operation', operation: vcsOp, command: toolInput.command });
            }
          }
        }
      }
    }

    if (message.type === 'user' && message.message?.content) {
      for (const block of message.message.content) {
        if (block.type === 'tool_result' && block.content) {
          const toolName = toolUseMap.get(block.tool_use_id);
          if (toolName) {
            const resultText = extractResultText(block.content);
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

      if (message.subtype === 'error_max_turns') {
        emit({ type: 'error', message: 'Max turns reached' });
      }
    }

    if (message.type === 'error') {
      const errorMessage = message.error?.message || message.message || 'Unknown error';
      if (errorMessage.includes('No conversation found') || errorMessage.includes('session')) {
        emit({
          type: 'session_corrupted',
          old_session_id: sessionId,
          reason: 'sdk_session_not_found',
        });
      } else {
        emit({ type: 'error', message: errorMessage });
      }
    }
  }

  emit({ type: 'done' });
}
