import { callNeovim } from '../rpc.js';

/**
 * Retrieve the current Neovim cursor position and return it as pretty-printed JSON in a content block.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON of the cursor position.
 */
export async function handleGetCursor(args: any) {
  const pos = await callNeovim('get_cursor_position', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(pos, null, 2) }],
  };
}

/**
 * Move Neovim's cursor to the specified line and optional column.
 *
 * @param args - Object containing cursor position; must include `line` (number). `col` (number) and
 * `winnr` (number) are optional. Without `winnr` the currently active window is moved, which is
 * not the one `nvim_win_open_file` just opened a file in — it restores focus before returning.
 * @returns An object with a `content` array containing a single text node confirming the new cursor line.
 * @throws Error if `args` is falsy or `args.line` is undefined with message 'Missing required parameter: line'.
 */
export async function handleSetCursor(args: any) {
  if (!args || args.line === undefined) {
    throw new Error('Missing required parameter: line');
  }
  await callNeovim(
    'set_cursor_position',
    {
      line: args.line,
      col: args.col,
      winnr: args.winnr,
    },
    args?.rpc_port
  );
  const where = args.winnr === undefined ? '' : ` in window ${args.winnr}`;
  return {
    content: [{ type: 'text', text: `Cursor moved to line ${args.line}${where}` }],
  };
}

/**
 * Fetches the current visual selection from Neovim and wraps its pretty-printed JSON in a content text node.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the pretty-printed JSON representation of the visual selection
 */
export async function handleGetVisualSelection(args: any) {
  const selection = await callNeovim('get_visual_selection', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(selection, null, 2) }],
  };
}
