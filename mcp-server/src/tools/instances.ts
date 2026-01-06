export const instanceTools = [
  {
    name: 'nvim_list_instances',
    description:
      'List all running Neovim instances with vibing.nvim RPC servers. Returns array of instances with pid, port, cwd, and started_at.',
    inputSchema: {
      type: 'object' as const,
      properties: {},
    },
  },
];
