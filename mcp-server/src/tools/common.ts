/**
 * Common RPC port property for all MCP tools
 *
 * Read-only tools may omit `rpc_port`; it then resolves through `resolveRpcPort` in `../rpc.ts` —
 * see that function for why env can't supply the port. Tools that change state keep it required
 * via `requireRpcPort` below. Inside vibing.nvim the model is told to pass the port embedded in
 * its system prompt (see `cli_command_builder.lua`) either way, because worktrees and concurrent
 * chats routinely mean more than one instance is live.
 */
export const rpcPortProperty = {
  rpc_port: {
    type: 'number' as const,
    // Every tool carries a copy of this string, so its length is multiplied by the tool count.
    // Keep it to the instruction; the reasoning behind it belongs in the comment above.
    description:
      'RPC port of the target Neovim instance (the value in your system prompt this turn). ' +
      'Never guess it; only reads may omit it.',
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
 * Mark a tool as one that must be pointed at an instance explicitly.
 *
 * Registry fallback is fine for reads — the worst case is answering about the wrong buffer. It is
 * not fine for tools that change state, because this MCP server is installed at Claude Code's
 * *user* scope: every Claude Code session on the machine sees these tools, including ones that
 * have nothing to do with vibing.nvim and were never given a port. Letting those omit `rpc_port`
 * would quietly hand them `nvim_execute`, `nvim_set_buffer` and `nvim_chat_send_message` against
 * whichever editor the user happens to have open.
 *
 * So: reads may omit it, writes must name their target.
 *
 * @param required Other required property names for the tool
 * @returns required array with 'rpc_port' included
 */
export function requireRpcPort(required: string[] = []): string[] {
  return ['rpc_port', ...required];
}
