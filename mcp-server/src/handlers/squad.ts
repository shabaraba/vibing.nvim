import { callNeovim } from '../rpc.js';
import { validateRequired } from '../validation/schema.js';

/**
 * Get squad information for a specific buffer
 *
 * @param args - Object with `bufnr` (optional, defaults to current), and optional `rpc_port`
 * @returns Squad metadata including squad_name, bufnr, buffer_name, task_ref (worktree path)
 */
export async function handleGetSquadInfo(args: any) {
  const info = await callNeovim(
    'get_squad_info',
    {
      bufnr: args?.bufnr,
    },
    args?.rpc_port
  );
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

/**
 * List all active squads in Neovim
 *
 * @param args - Object with optional `rpc_port`
 * @returns Array of squad entries with squad_name, bufnr, buffer_name, and metadata
 */
export async function handleListSquads(args: any) {
  const squads = await callNeovim('list_squads', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(squads, null, 2) }],
  };
}

/**
 * Find buffer number for a specific squad by name
 *
 * @param args - Object with `squad_name` (required) and optional `rpc_port`
 * @returns Buffer number and buffer_name if found, null otherwise
 */
export async function handleFindSquadBuffer(args: any) {
  validateRequired(args?.squad_name, 'squad_name');

  const result = await callNeovim(
    'find_squad_buffer',
    {
      squad_name: args.squad_name,
    },
    args?.rpc_port
  );
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
