/**
 * Common RPC port property for all MCP tools
 *
 * `rpc_port` is offered but not required. Omitting it resolves through `resolveRpcPort` in
 * `../rpc.ts` — see that function for why env can't supply the port and why the registry is only
 * consulted as a fallback. Inside vibing.nvim the model is still told to pass the port embedded in
 * its system prompt (see `cli_command_builder.lua`), because worktrees and concurrent chats
 * routinely mean more than one instance is live.
 */
export const rpcPortProperty = {
  rpc_port: {
    type: 'number' as const,
    // Every tool carries a copy of this string, so its length is multiplied by the tool count.
    // Keep it to the instruction; the reasoning behind it belongs in the comment above.
    description:
      'RPC port of the target Neovim instance (the value in your system prompt this turn). ' +
      'Never guess it; omit it only if you were given no such value.',
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
