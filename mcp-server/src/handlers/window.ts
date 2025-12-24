import { callNeovim } from '../rpc.js';

export async function handleListWindows(args: any) {
  const windows = await callNeovim('list_windows');
  return {
    content: [{ type: 'text', text: JSON.stringify(windows, null, 2) }],
  };
}

export async function handleGetWindowInfo(args: any) {
  const info = await callNeovim('get_window_info', { winnr: args?.winnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

export async function handleGetWindowView(args: any) {
  const view = await callNeovim('get_window_view', { winnr: args?.winnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(view, null, 2) }],
  };
}

export async function handleListTabpages(args: any) {
  const tabs = await callNeovim('list_tabpages');
  return {
    content: [{ type: 'text', text: JSON.stringify(tabs, null, 2) }],
  };
}

export async function handleSetWindowSize(args: any) {
  if (args?.width === undefined && args?.height === undefined) {
    throw new Error('At least one of width or height must be specified');
  }
  if (args?.width !== undefined) {
    await callNeovim('set_window_width', {
      winnr: args.winnr,
      width: args.width,
    });
  }
  if (args?.height !== undefined) {
    await callNeovim('set_window_height', {
      winnr: args.winnr,
      height: args.height,
    });
  }
  return {
    content: [{ type: 'text', text: 'Window size updated successfully' }],
  };
}

export async function handleFocusWindow(args: any) {
  if (!args || args.winnr === undefined) {
    throw new Error('Missing required parameter: winnr');
  }
  await callNeovim('focus_window', { winnr: args.winnr });
  return {
    content: [{ type: 'text', text: `Focused window ${args.winnr}` }],
  };
}

export async function handleWinSetBuf(args: any) {
  if (!args || args.winnr === undefined || args.bufnr === undefined) {
    throw new Error('Missing required parameters: winnr and bufnr');
  }
  await callNeovim('win_set_buf', {
    winnr: args.winnr,
    bufnr: args.bufnr,
  });
  return {
    content: [
      { type: 'text', text: `Set buffer ${args.bufnr} in window ${args.winnr}` },
    ],
  };
}

export async function handleWinOpenFile(args: any) {
  if (!args || args.winnr === undefined || !args.filepath) {
    throw new Error('Missing required parameters: winnr and filepath');
  }
  const result = await callNeovim('win_open_file', {
    winnr: args.winnr,
    filepath: args.filepath,
  });
  return {
    content: [
      {
        type: 'text',
        text: `Opened ${args.filepath} in window ${args.winnr} (buffer ${result.bufnr})`,
      },
    ],
  };
}
