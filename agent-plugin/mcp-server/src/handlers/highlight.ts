import { callNeovim } from '../rpc.js';

/**
 * Highlight a line range in a buffer for a short while.
 *
 * @param args - `bufnr` and `start_line` are required; `end_line` defaults to `start_line` and
 *   `duration_ms` defaults to 3000 on the Neovim side.
 * @returns A content block describing what was highlighted.
 * @throws Error when `bufnr` or `start_line` is missing.
 */
export async function handleHighlightRange(args: any) {
  if (!args || args.bufnr === undefined) {
    throw new Error('Missing required parameter: bufnr');
  }
  if (args.start_line === undefined) {
    throw new Error('Missing required parameter: start_line');
  }

  const result = await callNeovim(
    'highlight_range',
    {
      bufnr: args.bufnr,
      start_line: args.start_line,
      end_line: args.end_line,
      duration_ms: args.duration_ms,
    },
    args.rpc_port
  );

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Remove the highlight from a buffer before its timer runs out.
 *
 * @param args - `bufnr` is required.
 * @returns A content block confirming the clear.
 * @throws Error when `bufnr` is missing.
 */
export async function handleClearHighlight(args: any) {
  if (!args || args.bufnr === undefined) {
    throw new Error('Missing required parameter: bufnr');
  }

  const result = await callNeovim('clear_highlight', { bufnr: args.bufnr }, args.rpc_port);

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
