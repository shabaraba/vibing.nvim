import { withRpcPort, requireRpcPort } from './common.js';

export const annotationTools = [
  {
    name: 'nvim_annotate',
    description:
      'Attach a review note to a line, shown inline under it as virtual text. The file is not ' +
      'modified.',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current buffer)',
        },
        line: {
          type: 'number' as const,
          description: 'Line to annotate (1-indexed)',
        },
        text: {
          type: 'string' as const,
          description: 'Note body. Newlines become separate annotation lines.',
        },
        severity: {
          type: 'string' as const,
          enum: ['info', 'warn', 'error'],
          description: 'Colours the note (default "info")',
        },
      }),
      required: requireRpcPort(['bufnr', 'line', 'text']),
    },
  },
  {
    name: 'nvim_clear_annotations',
    description: 'Remove annotations from a buffer, or from every buffer when bufnr is omitted',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        bufnr: {
          type: 'number' as const,
          description: 'Buffer number (0 for current). Omit to clear every buffer.',
        },
      }),
      required: requireRpcPort(),
    },
  },
];
