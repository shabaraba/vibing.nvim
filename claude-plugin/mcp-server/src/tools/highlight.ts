import { withRpcPort, requireRpcPort } from './common.js';

export const highlightTools = [
  {
    name: 'nvim_highlight_range',
    description:
      'Temporarily highlight a line range so the user can see which code you mean. Pair with ' +
      'nvim_win_open_file and nvim_set_cursor to open the file and jump there first.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
        start_line: {
          type: 'number' as const,
          description: 'First line to highlight (1-indexed)',
        },
        end_line: {
          type: 'number' as const,
          description: 'Last line to highlight, inclusive (1-indexed, defaults to start_line)',
        },
        duration_ms: {
          type: 'number' as const,
          description:
            'Clear the highlight after this many milliseconds (default 3000). Pass 0 to leave it ' +
            'until the next highlight or nvim_clear_highlight.',
        },
      }),
      required: requireRpcPort(['bufnr', 'start_line']),
    },
  },
  {
    name: 'nvim_clear_highlight',
    description: 'Remove the nvim_highlight_range highlight from a buffer before it times out',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      }),
      required: requireRpcPort(['bufnr']),
    },
  },
];
