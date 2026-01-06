import { callNeovim } from '../rpc.js';
import { validateBufferParams, validateFilePath, validateRequired } from '../validation/schema.js';

/**
 * Retrieve the contents of a Neovim buffer and return them as a single text node.
 *
 * @param args - An object with `bufnr`, the buffer number to retrieve, and optional `rpc_port`.
 * @returns An object with `content` containing a single text node whose `text` is the buffer's contents (lines joined with `\n`).
 */
export async function handleGetBuffer(args: any) {
  if (args?.bufnr !== undefined) {
    validateBufferParams({ bufnr: args.bufnr });
  }
  const lines = await callNeovim('buf_get_lines', { bufnr: args?.bufnr }, args?.rpc_port);
  return {
    content: [{ type: 'text', text: lines.join('\n') }],
  };
}

/**
 * Update a Neovim buffer's lines.
 *
 * @param args - Object containing `lines` (array of strings), optional `bufnr` (buffer number), and optional `rpc_port`; `lines` are the new buffer contents.
 * @returns An object with content confirming the buffer was updated, including file path metadata.
 * @throws Error if `lines` is missing on `args`.
 */
export async function handleSetBuffer(args: any) {
  validateRequired(args?.lines, 'lines');
  if (args?.bufnr !== undefined) {
    validateBufferParams({ bufnr: args.bufnr });
  }

  const result = await callNeovim(
    'buf_set_lines',
    {
      lines: args.lines,
      bufnr: args.bufnr,
    },
    args?.rpc_port
  );

  // Include file path in response metadata for tracking modified files
  const metadata = result.filename
    ? { filename: result.filename, bufnr: result.bufnr }
    : { bufnr: result.bufnr };

  return {
    content: [
      {
        type: 'text',
        text: `Buffer updated successfully${result.filename ? ` (${result.filename})` : ''}`,
      },
    ],
    _meta: metadata, // Include metadata for agent-wrapper to track
  };
}

/**
 * Retrieve current file information from Neovim and return it as pretty-printed JSON in a content payload.
 *
 * @param args - Object with optional `rpc_port` to target specific Neovim instance.
 * @returns An object with a `content` array containing a single text node whose `text` is the JSON-formatted current file information.
 */
export async function handleGetInfo(args: any) {
  const info = await callNeovim('get_current_file', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

/**
 * Get a pretty-printed JSON representation of all Neovim buffers.
 *
 * @param args - Object with optional `rpc_port` to target specific Neovim instance.
 * @returns An object with a `content` array containing one text node whose `text` is the pretty-printed JSON list of buffers.
 */
export async function handleListBuffers(args: any) {
  const buffers = await callNeovim('list_buffers', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(buffers, null, 2) }],
  };
}

/**
 * Load a file into a Neovim buffer and return the operation result as pretty-printed JSON.
 *
 * @param args - Object containing parameters for loading the buffer.
 * @param args.filepath - Path to the file to load into the buffer; required.
 * @param args.rpc_port - Optional RPC port to target specific Neovim instance.
 * @returns An object with a `content` array containing a single text node with the JSON-formatted result.
 * @throws Error if `args` is missing or `args.filepath` is not provided or invalid.
 */
export async function handleLoadBuffer(args: any) {
  validateRequired(args?.filepath, 'filepath');
  validateFilePath({ filepath: args.filepath });

  const result = await callNeovim('load_buffer', { filepath: args.filepath }, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
