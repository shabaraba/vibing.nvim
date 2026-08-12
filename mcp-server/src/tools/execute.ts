import { withRpcPort, requireRpcPort } from './common.js';

export const executeTools = [
  {
    name: 'nvim_execute',
    description: 'Execute Neovim command',
    inputSchema: {
      type: 'object' as const,
      properties: withRpcPort({
        command: {
          type: 'string' as const,
          description: 'Neovim command to execute',
        },
      }),
      required: requireRpcPort(['command']),
    },
  },
];
