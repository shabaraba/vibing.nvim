import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort } from './common.js';

/**
 * The two prompts the model raises as queued tools.
 *
 * Neither call waits. Each returns as soon as Neovim has queued the entry on the calling turn, and
 * the chat draws it when the turn ends — so the model must end its turn immediately after the call
 * or the prompt is delayed. The answer is the next message, exactly as for a `vibing-question`
 * block. The fenced block stays as the fallback for a backend that cannot reach this server.
 */
export const ASK_QUESTION_TOOL = 'nvim_ask_question';
export const REQUEST_APPROVAL_TOOL = 'nvim_request_approval';

export const promptTools: Tool[] = [
  {
    name: ASK_QUESTION_TOOL,
    description:
      'Ask the user to choose among options (single- or multi-select). The call does NOT wait: ' +
      'it queues the question and returns immediately. End your turn right after it — vibing.nvim ' +
      'draws the options into the chat when the turn ends, and the answer arrives as the next ' +
      'message. At most 4 questions per call. Use this instead of the native AskUserQuestion ' +
      'tool, which is unavailable here.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        questions: {
          type: 'array' as const,
          minItems: 1,
          maxItems: 4,
          description: 'The questions to show, in order.',
          items: {
            type: 'object' as const,
            properties: {
              question: {
                type: 'string' as const,
                description: 'The question itself, shown above its options.',
              },
              multiSelect: {
                type: 'boolean' as const,
                description: 'Whether more than one option may be chosen (default false).',
              },
              options: {
                type: 'array' as const,
                minItems: 1,
                description: 'The choices offered for this question.',
                items: {
                  type: 'object' as const,
                  properties: {
                    label: {
                      type: 'string' as const,
                      minLength: 1,
                      description: 'Short label, shown next to its number or bullet.',
                    },
                    description: {
                      type: 'string' as const,
                      description: 'Optional one-line explanation shown under the label.',
                    },
                  },
                  required: ['label'],
                },
              },
            },
            required: ['options'],
          },
        },
      }),
      required: ['questions'],
    },
  },
  {
    name: REQUEST_APPROVAL_TOOL,
    description:
      'Ask the user to confirm something you are about to do (for example, deleting files). ' +
      'The call does NOT wait: it queues the request and returns immediately. End your turn right ' +
      'after it; vibing.nvim shows the confirmation with your reply, offering "Proceed" / ' +
      '"Do not proceed" lines, and the next message is the answer. This is NOT the tool-permission ' +
      'gate and does not authorise a later tool call — a gated call still has to pass the usual ' +
      'approval.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        reason: {
          type: 'string' as const,
          minLength: 1,
          description: 'What you are about to do, in your own words. Shown to the user.',
        },
        tool: {
          type: 'string' as const,
          description: 'Optional name of the tool this confirmation is about, e.g. "Bash".',
        },
        input: {
          type: 'object' as const,
          description:
            'Optional details of the call the user is confirming, such as { "command": "rm -rf build" } ' +
            'or { "file_path": "build/" }. Only command, file_path, pattern, url and details are shown.',
        },
      }),
      required: ['reason'],
    },
  },
];
