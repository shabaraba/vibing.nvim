import { withRpcPort } from './common.js';

export const windowTools = [
  {
    name: 'nvim_list_windows',
    description: 'List all windows with their properties',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_get_window_info',
    description:
      "Get one window's buffer, size, position and cursor. For its scroll position and visible " +
      'line range, use nvim_get_window_view.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number (0 for current window)',
        },
      }),
      required: [],
    },
  },
  {
    name: 'nvim_get_window_view',
    description:
      "Get one window's scroll position and visible line range. For its buffer, size and position, " +
      'use nvim_get_window_info.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number (0 for current window)',
        },
      }),
      required: [],
    },
  },
  {
    name: 'nvim_list_tabpages',
    description: 'List all tab pages with their windows',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_set_window_size',
    description: 'Resize window width and/or height',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number (0 for current window)',
        },
        width: {
          type: 'number' as const,
          description: 'Window width (optional)',
        },
        height: {
          type: 'number' as const,
          description: 'Window height (optional)',
        },
      }),
      required: [],
    },
  },
  {
    name: 'nvim_focus_window',
    description: 'Move focus to a specific window',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number to focus',
        },
      }),
      required: ['winnr'],
    },
  },
  {
    name: 'nvim_win_set_buf',
    description: 'Set an existing buffer in a specific window',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number',
        },
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number to display',
        },
      }),
      required: ['winnr', 'bufnr'],
    },
  },
  {
    name: 'nvim_win_open_file',
    description: 'Open a file in a specific window without switching focus',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        winnr: {
          type: 'number' as const,
          description: 'Window number',
        },
        filepath: {
          type: 'string' as const,
          description: 'Path to file to open',
        },
      }),
      required: ['winnr', 'filepath'],
    },
  },
];
