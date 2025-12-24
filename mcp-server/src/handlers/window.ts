import { callNeovim } from '../rpc.js';

/**
 * Retrieve the list of Neovim windows and return it as pretty-printed JSON in the response content.
 *
 * @returns The response object with a `content` array containing one text node whose `text` is the pretty-printed JSON representation of the window list.
 */
export async function handleListWindows(args: any) {
  const windows = await callNeovim('list_windows');
  return {
    content: [{ type: 'text', text: JSON.stringify(windows, null, 2) }],
  };
}

/**
 * Retrieve information for a specific Neovim window and return it as pretty-printed JSON inside a text content node.
 *
 * @param args - An object containing `winnr`, the window number to query
 * @returns An object with a `content` array whose first element is a text node containing the pretty-printed JSON window info
 */
export async function handleGetWindowInfo(args: any) {
  const info = await callNeovim('get_window_info', { winnr: args?.winnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(info, null, 2) }],
  };
}

/**
 * Retrieve the view state for a specified Neovim window.
 *
 * @param args - An object with a `winnr` property indicating the target window number.
 * @returns An object whose `content` is a single text node containing the pretty-printed JSON representation of the window view
 */
export async function handleGetWindowView(args: any) {
  const view = await callNeovim('get_window_view', { winnr: args?.winnr });
  return {
    content: [{ type: 'text', text: JSON.stringify(view, null, 2) }],
  };
}

/**
 * Retrieve the list of Neovim tabpages and return it as pretty-printed JSON inside a content node.
 *
 * @returns An object with a `content` array containing a single text node whose `text` is the JSON-stringified (2-space indented) tabpage list
 */
export async function handleListTabpages(args: any) {
  const tabs = await callNeovim('list_tabpages');
  return {
    content: [{ type: 'text', text: JSON.stringify(tabs, null, 2) }],
  };
}

/**
 * Update the width and/or height of a Neovim window.
 *
 * @param args - Handler arguments. Expected properties:
 *   - winnr: the window number to modify
 *   - width: new width in columns (optional)
 *   - height: new height in rows (optional)
 * @returns An object whose `content` is an array containing a text node confirming the update.
 * @throws Error if neither `width` nor `height` is provided
 */
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

/**
 * Focuses the Neovim window identified by the provided window number.
 *
 * @param args - Call arguments.
 * @param args.winnr - The window number to focus.
 * @returns An object whose `content` is an array with a single text node confirming the focused window (for example, "Focused window 1").
 * @throws Error if `winnr` is not provided on `args`.
 */
export async function handleFocusWindow(args: any) {
  if (!args || args.winnr === undefined) {
    throw new Error('Missing required parameter: winnr');
  }
  await callNeovim('focus_window', { winnr: args.winnr });
  return {
    content: [{ type: 'text', text: `Focused window ${args.winnr}` }],
  };
}

/**
 * Set the buffer displayed in a Neovim window.
 *
 * @param args - Object with `winnr` (window number) and `bufnr` (buffer number) to set
 * @throws Error if `winnr` or `bufnr` is missing
 * @returns An object with a `content` array containing a text node that confirms the buffer was set for the specified window
 */
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

/**
 * Open a file in the specified Neovim window and report the resulting buffer.
 *
 * @param args - Object containing call arguments:
 *   - `winnr`: the target window number
 *   - `filepath`: path of the file to open in the window
 * @returns An object whose `content` is a single text node describing the opened filepath, the window number, and the resulting buffer number.
 * @throws Error if `winnr` or `filepath` is missing from `args`.
 */
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
