import { callNeovim } from '../rpc.js';

export async function handleGetCursor(args: any) {
  const pos = await callNeovim('get_cursor_position');
  return {
    content: [{ type: 'text', text: JSON.stringify(pos, null, 2) }],
  };
}

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

export async function handleGetVisualSelection(args: any) {
  const selection = await callNeovim('get_visual_selection');
  return {
    content: [{ type: 'text', text: JSON.stringify(selection, null, 2) }],
  };
}
