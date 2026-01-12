/**
 * Shared buffer operations handlers for vibing.nvim MCP server
 */

import { createRpcRequest } from '../rpc.js';

/**
 * Check if there are unprocessed mentions for a specific Claude session
 */
export async function handleHasUnprocessedMentions(args: {
  rpc_port?: number;
}): Promise<{ has_mentions: boolean; count: number; claude_id?: string }> {
  const rpcPort = args.rpc_port || parseInt(process.env.VIBING_RPC_PORT || '9876', 10);

  const result = await createRpcRequest(rpcPort, 'has_unprocessed_mentions', {});

  if (result.error) {
    throw new Error(result.error);
  }

  return result.result;
}

/**
 * Get list of unprocessed mentions
 */
export async function handleGetUnprocessedMentions(args: {
  rpc_port?: number;
}): Promise<{
  mentions: Array<{
    message_id: string;
    timestamp: string;
    from_claude_id: string;
    content: string;
  }>;
}> {
  const rpcPort = args.rpc_port || parseInt(process.env.VIBING_RPC_PORT || '9876', 10);

  const result = await createRpcRequest(rpcPort, 'get_unprocessed_mentions', {});

  if (result.error) {
    throw new Error(result.error);
  }

  return result.result;
}
