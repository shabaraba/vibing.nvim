import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort, requireRpcPort } from './common.js';

/**
 * Chat-related MCP tools
 */

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_send_message',
    description:
      'Programmatically send a message to a chat buffer and trigger AI request. ' +
      'Useful for multi-agent workflows where one Claude instance sends messages to another.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        bufnr: {
          type: 'number',
          description: 'Buffer number of the target chat buffer',
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
      }),
      required: requireRpcPort(['bufnr', 'message']),
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
      'You MUST pass handle_id using the exact value given to you in your system prompt for this ' +
      'turn — it identifies which chat buffer to render the question in.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        handle_id: {
          type: 'string',
          description:
            'The exact handle_id value given to you in your system prompt for this turn. Required ' +
            'to associate this question with the correct chat buffer.',
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
      required: requireRpcPort(['handle_id', 'questions']),
    },
  },
];
