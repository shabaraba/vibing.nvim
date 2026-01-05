/**
 * Common RPC port property for all MCP tools
 * Allows targeting specific Neovim instance when multiple instances are running
 */
export const rpcPortProperty = {
  rpc_port: {
    type: 'number' as const,
    description:
      'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
  },
};

/**
 * Add rpc_port parameter to tool schema properties
 * @param properties Existing tool properties
 * @returns Properties with rpc_port added
 */
export function withRpcPort(properties: Record<string, any>): Record<string, any> {
  return {
    ...properties,
    ...rpcPortProperty,
  };
}
