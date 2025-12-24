import { callNeovim } from '../rpc.js';

export async function handleGetBuffer(args: any) {
  const lines = await callNeovim('buf_get_lines', { bufnr: args?.bufnr });
  return {
    content: [{ type: 'text', text: lines.join('\n') }],
  };
}

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

export async function handleGetInfo(args: any) {
  const info = await callNeovim('get_current_file');
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

export async function handleListBuffers(args: any) {
  const buffers = await callNeovim('list_buffers');
  return {
    content: [{ type: 'text', text: JSON.stringify(buffers, null, 2) }],
  };
}

export async function handleLoadBuffer(args: any) {
  if (!args || !args.filepath) {
    throw new Error('Missing required parameter: filepath');
  }
  const result = await callNeovim('load_buffer', { filepath: args.filepath });
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
