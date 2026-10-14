/**
 * Common RPC port property for all MCP tools
 *
 * vibing.nvim binds the MCP process to its Neovim instance through `VIBING_NVIM_RPC_PORT`, so
 * ordinary callers omit this property. It stays available as an optional compatibility override
 * for clients that launch the server manually; `rpc.ts` falls back to the instance registry when
 * neither source supplies a port.
 */
export const rpcPortProperty = {
  rpc_port: {
    type: 'number' as const,
    description: 'Optional legacy override for a manually launched server; normally omit it.',
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
