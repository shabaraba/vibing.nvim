/**
 * Common RPC port property for all MCP tools
 *
 * There is no safe default port: the MCP server process can't discover which Neovim instance
 * spawned it via env (the client only forwards a fixed OS-level whitelist plus this server's
 * static registration config — see `.claude-plugin/plugin.json`), and falling back to a fixed
 * port silently targets whatever unrelated Neovim instance happens to be bound to it when
 * multiple instances are running. The model must always supply the value embedded in its system
 * prompt for this turn (see `cli_command_builder.lua`).
 */
export const rpcPortProperty = {
  rpc_port: {
    type: 'number' as const,
    description:
      'RPC port of the target Neovim instance. Use the exact value given to you in your system ' +
      'prompt for this turn — do not guess or omit it, since multiple unrelated Neovim instances ' +
      'may be running.',
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

/**
 * Build a tool's `required` array with `rpc_port` always included, so the model can't silently
 * omit it and fall back to whichever Neovim instance happens to be on the default port.
 * @param required Other required property names for the tool
 * @returns required array with 'rpc_port' included
 */
export function requireRpcPort(required: string[] = []): string[] {
  return ['rpc_port', ...required];
}
