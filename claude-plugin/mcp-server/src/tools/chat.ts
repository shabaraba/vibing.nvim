import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort, requireRpcPort } from './common.js';

/**
 * Chat-related MCP tools
 */

/**
 * Window positions nvim_chat_create accepts, mirroring `lua/vibing/core/constants/chat.lua`.
 * Exported so the handler's zod schema validates against the same list the advertised schema
 * offers — otherwise the two can drift and a value one accepts the other rejects.
 */
export const CHAT_POSITIONS = ['back', 'current', 'right', 'left', 'top', 'bottom'] as const;

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_create',
    description:
      'Create a new vibing.nvim chat buffer and return its bufnr and chat file path. ' +
      'Use it to spawn worker chats you then drive with nvim_chat_send_message — the ' +
      'multi-agent orchestration workflow (see the vibing-orchestrate skill). ' +
      'Leave position at its "back" default for workers: that creates the buffer without ' +
      "opening a window, so the user's layout is untouched. " +
      'The new chat starts empty and shares nothing with yours, so every message you send it ' +
      'must be self-contained.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        position: {
          type: 'string',
          enum: [...CHAT_POSITIONS],
          description:
            'Where to put the chat window (default "back": buffer only, no window). ' +
            'Same values as :VibingChat.',
        },
        working_dir: {
          type: 'string',
          description:
            'Optional working directory for the chat, as a path relative to the git root ' +
            '(e.g. ".vibing/worktrees/fix-auth"). Must already exist. Omit to use the ' +
            "Neovim instance's own working directory.",
        },
        from_bufnr: {
          type: 'number',
          description:
            'Your own chat: the exact "Current vibing.nvim chat buffer number" from your ' +
            'system prompt. Pass it whenever you create a worker — it records the ' +
            'relationship in both chat files, which survives renames and restarts.',
        },
      }),
      required: requireRpcPort([]),
    },
  },
  {
    name: 'nvim_chat_send_message',
    description:
      'Programmatically send a message to a chat buffer and trigger AI request. ' +
      'Useful for multi-agent workflows where one Claude instance sends messages to another. ' +
      'Name the target with either file_path or bufnr, not both. Prefer file_path: a buffer ' +
      'number only means anything in the Neovim session that issued it, while the chat file ' +
      'path is what the chats record in their own frontmatter, so it still reaches the right ' +
      'chat after a restart — and a chat that is not open is opened for you.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        file_path: {
          type: 'string',
          description:
            'Chat file of the target chat, as returned by nvim_chat_create or written in ' +
            'frontmatter (git-root-relative, absolute, or ~-prefixed). Opened in the background ' +
            'if it is not already open. Must name a vibing.nvim chat file.',
        },
        bufnr: {
          type: 'number',
          description:
            'Buffer number of the target chat buffer. Only valid within this Neovim session — ' +
            'use file_path instead when you have one.',
        },
        message: {
          type: 'string',
          description: 'Message content to send',
        },
        sender: {
          type: 'string',
          description:
            'Optional sender identifier (default: "User"). Future: supports "Alpha", "Bravo", etc.',
        },
        from_bufnr: {
          type: 'number',
          description:
            'Your own chat: the exact "Current vibing.nvim chat buffer number" from your ' +
            'system prompt. Pass it whenever you drive another chat — it records the ' +
            'relationship in both chat files, which survives renames and restarts.',
        },
      }),
      // Neither bufnr nor file_path is required on its own; the handler enforces that exactly one
      // arrives. JSON Schema could say that with oneOf, but the advertised schema is flattened
      // into the model's tool list, and a required-list of two mutually exclusive keys reads as
      // "pass both".
      required: requireRpcPort(['message']),
    },
  },
  {
    name: 'nvim_ask_user_question',
    description:
      'Ask the user one or more multiple-choice questions directly in the vibing.nvim chat buffer. ' +
      'Use this instead of asking questions in free text, and instead of the native AskUserQuestion ' +
      'tool (which is unavailable in headless CLI mode). ' +
      'IMPORTANT: calling this tool renders the questions as an editable choice list in the chat ' +
      'buffer and then immediately cancels/kills your current turn — you will NOT get a normal ' +
      'tool_result back, and you cannot do anything else after calling it. The user edits the list ' +
      "(deleting unwanted options) and sends it. Your NEXT invocation's prompt IS the user's answer " +
      'to this question, delivered as a fresh turn — treat it as such rather than waiting for a ' +
      'tool response. ' +
      'You MUST pass chat_bufnr using the exact "Current vibing.nvim chat buffer number" value ' +
      'given to you in your system prompt — it identifies which chat buffer to render the ' +
      'question in.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        chat_bufnr: {
          type: 'number',
          description:
            'The exact "Current vibing.nvim chat buffer number" given to you in your system ' +
            'prompt. Required to associate this question with the correct chat buffer.',
        },
        questions: {
          type: 'array',
          description: 'One or more questions to present to the user',
          items: {
            type: 'object',
            properties: {
              question: {
                type: 'string',
                description: 'The question text',
              },
              multiSelect: {
                type: 'boolean',
                description: 'Whether multiple options can be selected (default: false)',
              },
              options: {
                type: 'array',
                description: 'The choices offered to the user',
                items: {
                  type: 'object',
                  properties: {
                    label: {
                      type: 'string',
                      description: 'The option text shown to the user',
                    },
                    description: {
                      type: 'string',
                      description: 'Optional additional detail shown under the option',
                    },
                  },
                  required: ['label'],
                },
              },
            },
            required: ['question', 'options'],
          },
        },
      }),
      required: requireRpcPort(['chat_bufnr', 'questions']),
    },
  },
];
