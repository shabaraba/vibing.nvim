import { callNeovim } from '../rpc.js';

/**
 * Retrieve the current Neovim cursor position and return it as pretty-printed JSON in a content block.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON of the cursor position.
 */
export async function handleGetCursor(args: any) {
  const pos = await callNeovim('get_cursor_position');
  return {
    content: [{ type: 'text', text: JSON.stringify(pos, null, 2) }],
  };
}

/**
 * Move Neovim's cursor to the specified line and optional column.
 *
 * @param args - Object containing cursor position; must include `line` (number). `col` (number) is optional.
 * @returns An object with a `content` array containing a single text node confirming the new cursor line.
 * @throws Error if `args` is falsy or `args.line` is undefined with message 'Missing required parameter: line'.
 */
export async function handleSetCursor(args: any) {
  if (!args || args.line === undefined) {
    throw new Error('Missing required parameter: line');
  }
  await callNeovim('set_cursor_position', {
    line: args.line,
    col: args.col,
  });
  return {
    content: [{ type: 'text', text: `Cursor moved to line ${args.line}` }],
  };
}

/**
 * Fetches the current visual selection from Neovim and wraps its pretty-printed JSON in a content text node.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the visual selection
 */
export async function handleGetVisualSelection(args: any) {
  const selection = await callNeovim('get_visual_selection');
  return {
    content: [{ type: 'text', text: JSON.stringify(selection, null, 2) }],
  };
}
