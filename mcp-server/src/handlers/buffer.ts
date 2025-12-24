import { callNeovim } from '../rpc.js';

/**
 * Retrieve the contents of a Neovim buffer and return them as a single text node.
 *
 * @param args - An object with `bufnr`, the buffer number to retrieve.
 * @returns An object with `content` containing a single text node whose `text` is the buffer's contents (lines joined with `\n`).
 */
export async function handleGetBuffer(args: any) {
  const lines = await callNeovim('buf_get_lines', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: lines.join('\n') }],
  };
}

/**
 * Update a Neovim buffer's lines.
 *
 * @param args - Object containing `lines` (array of strings) and optional `bufnr` (buffer number); `lines` are the new buffer contents.
 * @returns An object with a single text content node confirming the buffer was updated.
 * @throws Error if `lines` is missing on `args`.
 */
export async function handleSetBuffer(args: any) {
  if (!args || !args.lines) {
    throw new Error('Missing required parameter: lines');
  }
  await callNeovim('buf_set_lines', {
    lines: args.lines,
    bufnr: args.bufnr,
  });
  return {
    content: [{ type: 'text', text: 'Buffer updated successfully' }],
  };
}

/**
 * Retrieve current file information from Neovim and return it as pretty-printed JSON in a content payload.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the JSON-formatted current file information.
 */
export async function handleGetInfo(args: any) {
  const info = await callNeovim('get_current_file');
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

/**
 * Get a pretty-printed JSON representation of all Neovim buffers.
 *
 * @returns An object with a `content` array containing one text node whose `text` is the pretty-printed JSON list of buffers.
 */
export async function handleListBuffers(args: any) {
  const buffers = await callNeovim('list_buffers');
  return {
    content: [{ type: 'text', text: JSON.stringify(buffers, null, 2) }],
  };
}

/**
 * Load a file into a Neovim buffer and return the operation result as pretty-printed JSON.
 *
 * @param args - Object containing parameters for loading the buffer.
 * @param args.filepath - Path to the file to load into the buffer; required.
 * @returns An object with a `content` array containing a single text node with the JSON-formatted result.
 * @throws Error if `args` is missing or `args.filepath` is not provided.
 */
export async function handleLoadBuffer(args: any) {
  if (!args || !args.filepath) {
    throw new Error('Missing required parameter: filepath');
  }
  const result = await callNeovim('load_buffer', { filepath: args.filepath });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
