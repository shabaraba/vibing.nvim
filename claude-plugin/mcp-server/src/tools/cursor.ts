import { withRpcPort, requireRpcPort } from './common.js';

export const cursorTools = [
  {
    name: 'nvim_get_cursor',
    description: 'Get cursor position',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_set_cursor',
    description:
      'Set cursor position. Pass winnr when you opened the file with nvim_win_open_file — that ' +
      'tool leaves focus where it was, so without winnr this moves the cursor of whatever window ' +
      'is currently active (usually the chat), not the file you just opened.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        line: {
          type: 'number' as const,
          description: 'Line number (1-indexed)',
        },
        col: {
          type: 'number' as const,
          description: 'Column number (0-indexed)',
        },
        winnr: {
          type: 'number' as const,
          description:
            'Window to move the cursor in, as returned by nvim_list_windows. Defaults to the currently active window.',
        },
      }),
      required: requireRpcPort(['line']),
    },
  },
  {
    name: 'nvim_get_visual_selection',
    description: 'Get visual selection range and content',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
];
