import { withRpcPort, requireRpcPort } from './common.js';

export const bufferTools = [
  {
    name: 'nvim_get_buffer',
    description:
      'Get current buffer content. For a vibing.nvim chat buffer the result also reports ' +
      'whether a reply is being streamed into it right now — poll this to tell whether a ' +
      'worker chat has finished. Read a chat by file_path rather than bufnr when you have one: ' +
      'the path keeps working after a restart, and a chat that is not open is opened for you. ' +
      'For a large buffer, use tail_lines or last_section instead of reading it all — the result ' +
      "always reports the buffer's total line count so you know what you did not see.",
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
        file_path: {
          type: 'string' as const,
          description:
            'vibing.nvim chat file to read instead of a bufnr (git-root-relative, absolute, or ' +
            '~-prefixed). Opened in the background if it is not already open. Chat files only — ' +
            'use nvim_load_buffer for an ordinary file. Mutually exclusive with bufnr.',
        },
        tail_lines: {
          type: 'number' as const,
          description:
            'Return only the last N lines instead of the whole buffer. Combine with ' +
            'last_section to take the last N lines of the last section rather than of the ' +
            'whole buffer.',
        },
        last_section: {
          type: 'boolean' as const,
          description:
            'Return only the buffer\'s last section (cut at the last "## Assistant" / "## User" ' +
            '/ "## Request" / "## Report" / "## Notice" heading) instead of the whole buffer.',
        },
      }),
      required: [],
    },
  },
  {
    name: 'nvim_set_buffer',
    description: 'Replace buffer content',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        lines: {
          type: 'string' as const,
          description: 'New content (newline-separated)',
        },
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
      }),
      required: requireRpcPort(['lines']),
    },
  },
  {
    name: 'nvim_get_info',
    description:
      'Get metadata for the current file only (filepath, filetype, bufnr) — no content. Use ' +
      'nvim_get_buffer for content, and pass it a bufnr to reach a buffer other than the current one.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_list_buffers',
    description: 'List all loaded buffers',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({}),
      required: [],
    },
  },
  {
    name: 'nvim_load_buffer',
    description:
      'Load a file into a buffer without displaying it, and return its bufnr. Use this to give the ' +
      'LSP tools a buffer to work on without changing what the user is looking at.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        filepath: {
          type: 'string' as const,
          description: 'Absolute or relative path to file to load',
        },
      }),
      required: requireRpcPort(['filepath']),
    },
  },
];
