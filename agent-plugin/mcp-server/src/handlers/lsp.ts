import { callNeovim } from '../rpc.js';
import { LSP_BUFFER_METHODS, LSP_POSITION_METHODS } from '../tools/lsp.js';

const POSITION = new Set<string>(LSP_POSITION_METHODS);
const BUFFER = new Set<string>(LSP_BUFFER_METHODS);

/**
 * Ask Neovim for one `nvim_lsp` method. Each RPC method is written as a literal on purpose:
 * `read-only-methods.test.ts` finds the methods a handler calls by scanning for
 * `callNeovim('<name>'`, and an indirection through a lookup table would hide them from it.
 */
function query(method: string, params: Record<string, unknown>, rpcPort: number | undefined) {
  switch (method) {
    case 'definition':
      return callNeovim('lsp_definition', params, rpcPort);
    case 'references':
      return callNeovim('lsp_references', params, rpcPort);
    case 'hover':
      return callNeovim('lsp_hover', params, rpcPort);
    case 'type_definition':
      return callNeovim('lsp_type_definition', params, rpcPort);
    case 'call_hierarchy_incoming':
      return callNeovim('lsp_call_hierarchy_incoming', params, rpcPort);
    case 'call_hierarchy_outgoing':
      return callNeovim('lsp_call_hierarchy_outgoing', params, rpcPort);
    case 'document_symbols':
      return callNeovim('lsp_document_symbols', params, rpcPort);
    default:
      return callNeovim('diagnostics_get', params, rpcPort);
  }
}

/**
 * Serve one `nvim_lsp` call.
 *
 * @throws Error for an unknown `method`, or a position method called without `line` and `col`
 */
export async function handleLsp(args: any) {
  const method = args?.method;
  if (!POSITION.has(method) && !BUFFER.has(method)) {
    throw new Error(
      `Unknown method ${JSON.stringify(method)}; expected one of ` +
        [...LSP_POSITION_METHODS, ...LSP_BUFFER_METHODS].join(', ')
    );
  }
  const params: Record<string, unknown> = { bufnr: args.bufnr };
  if (POSITION.has(method)) {
    if (args.line === undefined || args.col === undefined) {
      throw new Error(`Missing required parameters for ${method}: line and col`);
    }
    params.line = args.line;
    params.col = args.col;
  }
  const result = await query(method, params, args.rpc_port);
  if (method === 'hover') {
    return {
      content: [{ type: 'text', text: result.contents || 'No hover information available' }],
    };
  }
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
