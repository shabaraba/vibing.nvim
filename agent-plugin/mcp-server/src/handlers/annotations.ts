import { callNeovim } from '../rpc.js';

/**
 * Attach an inline review note to a line.
 *
 * @param args - `bufnr`, `line` and `text` are required; `severity` defaults to "info".
 * @returns A content block with the created extmark id.
 * @throws Error when `bufnr`, `line` or `text` is missing.
 */
export async function handleAnnotate(args: any) {
  if (!args || args.bufnr === undefined) {
    throw new Error('Missing required parameter: bufnr');
  }
  if (args.line === undefined) {
    throw new Error('Missing required parameter: line');
  }
  if (args.text === undefined) {
    throw new Error('Missing required parameter: text');
  }

  const result = await callNeovim(
    'annotate',
    {
      bufnr: args.bufnr,
      line: args.line,
      text: args.text,
      severity: args.severity,
    },
    args.rpc_port
  );

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Remove annotations from one buffer, or from all of them.
 *
 * @param args - `bufnr` is optional; omitting it clears every buffer.
 * @returns A content block listing the buffers that had annotations removed.
 */
export async function handleClearAnnotations(args: any) {
  const result = await callNeovim('clear_annotations', { bufnr: args?.bufnr }, args?.rpc_port);

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
