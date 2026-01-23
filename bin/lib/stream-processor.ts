/**
 * Processes Agent SDK response stream and outputs JSON Lines format.
 */

import { safeJsonStringify } from './utils.js';
import { detectVcsOperation } from './vcs-detector.js';
import type { AgentConfig } from '../types.js';

/**
 * Emit a JSON-formatted message to stdout
 * @param obj - Object to serialize and output
 */
function emit(obj: Record<string, unknown>): void {
  console.log(safeJsonStringify(obj));
}

// Timeout constant for initial message (120 seconds)
const INITIAL_MESSAGE_TIMEOUT_MS = 120_000;

/**
 * Creates a cancellable timeout promise.
 * Returns an object with the promise and a cancel function to prevent resource leaks.
 */
function createCancellableTimeout(ms: number): {
  promise: Promise<never>;
  cancel: () => void;
} {
  let timeoutId: ReturnType<typeof setTimeout>;
  const promise = new Promise<never>((_, reject) => {
    timeoutId = setTimeout(
      () => reject(new Error('Stream timeout: no response from Agent SDK')),
      ms
    );
  });
  return {
    promise,
    cancel: () => clearTimeout(timeoutId),
  };
}

/**
 * Wraps an async iterable with a timeout for the first message.
 * This helps detect hung streams, especially during session resume.
 * The timeout is properly cancelled after receiving the first message to prevent resource leaks.
 */
async function* withInitialTimeout<T>(
  stream: AsyncIterable<T>,
  timeoutMs: number
): AsyncIterable<T> {
  const iterator = stream[Symbol.asyncIterator]();
  let isFirstMessage = true;
  let timeout: { promise: Promise<never>; cancel: () => void } | null = null;

  try {
    while (true) {
      let result: IteratorResult<T>;
      if (isFirstMessage) {
        // Apply timeout only for the first message
        timeout = createCancellableTimeout(timeoutMs);
        try {
          result = await Promise.race([iterator.next(), timeout.promise]);
          // Cancel timeout after receiving first message
          timeout.cancel();
          timeout = null;
          isFirstMessage = false;
        } catch (error) {
          // Ensure timeout is cancelled even on error
          timeout?.cancel();
          throw error;
        }
      } else {
        result = await iterator.next();
      }

      if (result.done) break;
      yield result.value;
    }
  } finally {
    // Ensure cleanup in case of early termination
    timeout?.cancel();
    // Clean up the iterator to prevent resource leaks
    await iterator.return?.();
  }
}

/**
 * Extract a brief summary from tool input for display
 * @param toolName - Name of the tool being invoked
 * @param toolInput - Tool input parameters
 * @returns Brief summary string for display
 */
function extractInputSummary(toolName: string, toolInput: Record<string, unknown>): string {
  // For Task tool, show subagent_type or prompt
  if (toolName === 'Task') {
    if (toolInput.subagent_type && typeof toolInput.subagent_type === 'string') {
      const subagentType = toolInput.subagent_type.trim();
      return subagentType || 'default';
    }
    // Fallback to prompt (truncated)
    if (toolInput.prompt && typeof toolInput.prompt === 'string') {
      const prompt = toolInput.prompt.trim();
      if (prompt) {
        return prompt.length > 30 ? prompt.substring(0, 30) + '...' : prompt;
      }
    }
    return 'default';
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

/**
 * Extract text from tool result content
 * @param content - Tool result content (string or array of content blocks)
 * @returns Extracted text content
 */
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

/**
 * Tracks Task tool context for nested tool display
 */
interface TaskToolContext {
  taskToolId: string;
  taskInputSummary: string;
  nestedToolIds: string[];
}

/**
 * Format TodoWrite todos list with emoji status indicators
 * @param todos - Array of todo items from tool input
 * @returns Formatted todo list with emojis
 */
function getStatusEmoji(status: TodoItem['status']): string {
  switch (status) {
    case 'completed':
      return '✅';
    case 'in_progress':
      return '🔄';
    default:
      return '⏳';
  }
}

function formatTodoWriteTodos(todos: TodoItem[]): string {
  const lines = todos.map((todo) => {
    const emoji = getStatusEmoji(todo.status);
    const displayText = todo.status === 'in_progress' ? todo.activeForm : todo.content;
    return `  ${emoji} ${displayText}`;
  });

  return '\n' + lines.join('\n') + '\n';
}

type DisplayMode = 'none' | 'compact' | 'full';

interface FormatToolResultOptions {
  toolName: string;
  inputSummary: string;
  resultText: string;
  displayMode: DisplayMode;
  prefixNewline: boolean;
  todos?: TodoItem[];
  parentTaskSummary?: string;
}

/**
 * Format tool execution result for display
 */
function formatToolResult(options: FormatToolResultOptions): string {
  const {
    toolName,
    inputSummary,
    resultText,
    displayMode,
    prefixNewline,
    todos,
    parentTaskSummary,
  } = options;

  const prefix = prefixNewline ? '\n' : '';
  const parentAnnotation = parentTaskSummary ? ` by Task(${parentTaskSummary})` : '';
  let text = `${prefix}⏺ ${toolName}(${inputSummary})${parentAnnotation}\n`;

  if (toolName === 'TodoWrite' && todos && todos.length > 0) {
    text += formatTodoWriteTodos(todos);
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

/**
 * Format Task tool completion message
 */
function formatTaskCompletion(
  inputSummary: string,
  nestedToolCount: number,
  prefixNewline: boolean
): string {
  const prefix = prefixNewline ? '\n' : '';
  return `${prefix}⏺ Task(${inputSummary}) ✓ (${nestedToolCount} tools used)\n`;
}

/**
 * Process Agent SDK response stream and emit JSON Lines to stdout
 * @param resultStream - Agent SDK response stream
 * @param toolResultDisplay - Tool result display mode
 * @param sessionId - Current session ID (if any)
 * @param cwd - Current working directory
 * @param config - Agent configuration
 */
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
  const todoWriteInputMap = new Map<string, TodoItem[]>();

  // Task tool tracking for nested display
  const taskContextMap = new Map<string, TaskToolContext>(); // taskToolId → context
  const toolParentMap = new Map<string, string>(); // tool_use_id → parent_task_id

  // Apply timeout for first message to detect hung streams during resume
  const stream = withInitialTimeout(resultStream, INITIAL_MESSAGE_TIMEOUT_MS);

  for await (const message of stream) {
    if (
      message.type === 'system' &&
      message.subtype === 'init' &&
      message.session_id &&
      !sessionIdEmitted
    ) {
      emit({ type: 'session', session_id: message.session_id });
      sessionIdEmitted = true;
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

          // TodoWriteの場合はtodosをキャプチャ
          if (toolName === 'TodoWrite' && toolInput.todos && Array.isArray(toolInput.todos)) {
            todoWriteInputMap.set(block.id, toolInput.todos as TodoItem[]);
          }

          // Track Task tools for nested display
          if (toolName === 'Task') {
            taskContextMap.set(block.id, {
              taskToolId: block.id,
              taskInputSummary: inputSummary,
              nestedToolIds: [],
            });

            // Display Task tool start immediately
            const taskText =
              (lastOutputType === 'text' ? '\n' : '') + `⏺ Task(${inputSummary}) ...\n`;
            emit({ type: 'chunk', text: taskText });
            lastOutputType = 'tool_result';
          }

          // Track parent-child relationship
          const parentToolUseId = (message as any).parent_tool_use_id;
          if (parentToolUseId && typeof parentToolUseId === 'string') {
            toolParentMap.set(block.id, parentToolUseId);
            // Add to parent Task's nested tool list
            const parentContext = taskContextMap.get(parentToolUseId);
            if (parentContext) {
              parentContext.nestedToolIds.push(block.id);
            }
          }

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
        if (block.type === 'tool_result') {
          const toolName = toolUseMap.get(block.tool_use_id);
          if (!toolName) continue;

          const resultText = block.content ? extractResultText(block.content) : '';
          const inputSummary = toolInputMap.get(block.tool_use_id) || '';
          const todos = todoWriteInputMap.get(block.tool_use_id);
          const prefixNewline = lastOutputType === 'text';

          let outputText: string;

          if (toolName === 'Task') {
            const taskContext = taskContextMap.get(block.tool_use_id);
            const nestedCount = taskContext ? taskContext.nestedToolIds.length : 0;
            outputText = formatTaskCompletion(inputSummary, nestedCount, prefixNewline);
          } else {
            const parentTaskId = toolParentMap.get(block.tool_use_id);
            const parentContext = parentTaskId ? taskContextMap.get(parentTaskId) : null;
            const parentTaskSummary = parentContext?.taskInputSummary;

            outputText = formatToolResult({
              toolName,
              inputSummary,
              resultText,
              displayMode: toolResultDisplay,
              prefixNewline,
              todos,
              parentTaskSummary,
            });
          }

          emit({ type: 'chunk', text: outputText });
          lastOutputType = 'tool_result';

          toolUseMap.delete(block.tool_use_id);
          toolInputMap.delete(block.tool_use_id);
          todoWriteInputMap.delete(block.tool_use_id);
          toolParentMap.delete(block.tool_use_id);
          taskContextMap.delete(block.tool_use_id);
        }
      }
    }

    if (message.type === 'result') {
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
