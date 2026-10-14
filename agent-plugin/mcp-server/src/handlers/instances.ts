import { listLiveInstances } from '../instance-registry.js';

/**
 * List all running Neovim instances with vibing.nvim RPC servers
 *
 * Reads instance registry from platform-specific data directory
 * and returns information about each running instance including PID, port, cwd, and start time.
 *
 * @param args - Unused, accepts any arguments for MCP compatibility
 * @returns Object with content array containing JSON-formatted instances list
 */
export async function handleListInstances(args: any) {
  const instances = await listLiveInstances();

  return {
    content: [
      {
        type: 'text',
        text: JSON.stringify({ instances }, null, 2),
      },
    ],
  };
}
