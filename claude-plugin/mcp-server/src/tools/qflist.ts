import type { Tool } from '@modelcontextprotocol/sdk/types.js';
import { withRpcPort, requireRpcPort } from './common.js';

export const qflistTools: Tool[] = [
  {
    name: 'nvim_set_qflist',
    description:
      'Push a route of file:line stops into the quickfix list so the user can replay it with ' +
      ':cnext/:cprev after you are done explaining. Always creates a NEW list, so whatever was ' +
      'in quickfix before stays reachable with :colder. Call it once per tour, with every stop ' +
      'in visiting order — a second call pushes a second list and desyncs :cnext from the tour ' +
      'you are narrating. Note col is 1-based here (native quickfix), unlike the 0-based col in ' +
      'nvim_set_cursor and the nvim_lsp_* results.',
    inputSchema: {
      type: 'object',
      properties: withRpcPort({
        items: {
          type: 'array',
          description: 'Stops in visiting order. Must not be empty.',
          items: {
            type: 'object',
            properties: {
              filename: {
                type: 'string',
                description: 'Existing file, absolute or relative to the Neovim cwd.',
              },
              lnum: { type: 'number', description: '1-based line number.' },
              col: { type: 'number', description: 'Optional 1-based column.' },
              text: {
                type: 'string',
                description: 'Short label shown for this stop in the quickfix window.',
              },
            },
            required: ['filename', 'lnum'],
          },
        },
        title: {
          type: 'string',
          description: 'Quickfix list title, e.g. "Code tour: auth flow".',
        },
        open: {
          type: 'boolean',
          description: 'Open the quickfix window too. Focus stays where it is.',
        },
      }),
      required: requireRpcPort(['items']),
    },
  },
];
