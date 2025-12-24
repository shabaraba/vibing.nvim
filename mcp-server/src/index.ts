#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import * as net from 'net';

const NVIM_RPC_PORT = parseInt(process.env.VIBING_RPC_PORT || '9876', 10);

let requestId = 0;
const pendingRequests = new Map<
  number,
  {
    resolve: (value: any) => void;
    reject: (error: Error) => void;
  }
>();

let socket: net.Socket | null = null;
let buffer = '';

/**
 * Get or create socket connection to Neovim RPC server
 */
function getSocket(): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    if (socket && !socket.destroyed) {
      resolve(socket);
      return;
    }

    socket = new net.Socket();

    socket.on('data', (data) => {
      buffer += data.toString();

      while (true) {
        const newlinePos = buffer.indexOf('\n');
        if (newlinePos === -1) break;

        const line = buffer.slice(0, newlinePos);
        buffer = buffer.slice(newlinePos + 1);

        try {
          const response = JSON.parse(line);
          const pending = pendingRequests.get(response.id);
          if (pending) {
            pendingRequests.delete(response.id);
            if (response.error) {
              pending.reject(new Error(response.error));
            } else {
              pending.resolve(response.result);
            }
          }
        } catch (e) {
          // Ignore parse errors
        }
      }
    });

    socket.on('error', (err) => {
      reject(err);
    });

    socket.on('close', () => {
      socket = null;
      // Reject all pending requests
      for (const [id, pending] of pendingRequests) {
        pending.reject(new Error('Socket closed'));
        pendingRequests.delete(id);
      }
    });

    socket.connect(NVIM_RPC_PORT, '127.0.0.1', () => {
      resolve(socket!);
    });
  });
}

/**
 * Call Neovim RPC method
 */
async function callNeovim(method: string, params: any = {}): Promise<any> {
  const sock = await getSocket();
  const id = ++requestId;

  return new Promise((resolve, reject) => {
    pendingRequests.set(id, { resolve, reject });

    const request = JSON.stringify({ id, method, params }) + '\n';
    sock.write(request);

    // Timeout after 5 seconds
    setTimeout(() => {
      if (pendingRequests.has(id)) {
        pendingRequests.delete(id);
        reject(new Error('Request timeout'));
      }
    }, 5000);
  });
}

// MCP Server setup
const server = new Server(
  {
    name: 'vibing-nvim',
    version: '0.1.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: 'nvim_get_buffer',
        description: 'Get current buffer content',
        inputSchema: {
          type: 'object',
          properties: {
            bufnr: {
              type: 'number',
              description: 'Buffer number (0 for current buffer)',
            },
          },
        },
      },
      {
        name: 'nvim_set_buffer',
        description: 'Replace buffer content',
        inputSchema: {
          type: 'object',
          properties: {
            lines: {
              type: 'string',
              description: 'New content (newline-separated)',
            },
            bufnr: {
              type: 'number',
              description: 'Buffer number (0 for current buffer)',
            },
          },
          required: ['lines'],
        },
      },
      {
        name: 'nvim_get_info',
        description: 'Get current file information',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_execute',
        description: 'Execute Neovim command',
        inputSchema: {
          type: 'object',
          properties: {
            command: {
              type: 'string',
              description: 'Neovim command to execute',
            },
          },
          required: ['command'],
        },
      },
      {
        name: 'nvim_list_buffers',
        description: 'List all loaded buffers',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_get_cursor',
        description: 'Get cursor position',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_set_cursor',
        description: 'Set cursor position',
        inputSchema: {
          type: 'object',
          properties: {
            line: {
              type: 'number',
              description: 'Line number (1-indexed)',
            },
            col: {
              type: 'number',
              description: 'Column number (0-indexed)',
            },
          },
          required: ['line'],
        },
      },
      {
        name: 'nvim_get_visual_selection',
        description: 'Get visual selection range and content',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_list_windows',
        description: 'List all windows with their properties',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_get_window_info',
        description: 'Get detailed information for a specific window',
        inputSchema: {
          type: 'object',
          properties: {
            winnr: {
              type: 'number',
              description: 'Window number (0 for current window)',
            },
          },
        },
      },
      {
        name: 'nvim_get_window_view',
        description: 'Get window viewport information (visible line range, scroll position)',
        inputSchema: {
          type: 'object',
          properties: {
            winnr: {
              type: 'number',
              description: 'Window number (0 for current window)',
            },
          },
        },
      },
      {
        name: 'nvim_list_tabpages',
        description: 'List all tab pages with their windows',
        inputSchema: {
          type: 'object',
          properties: {},
        },
      },
      {
        name: 'nvim_set_window_size',
        description: 'Resize window width and/or height',
        inputSchema: {
          type: 'object',
          properties: {
            winnr: {
              type: 'number',
              description: 'Window number (0 for current window)',
            },
            width: {
              type: 'number',
              description: 'Window width (optional)',
            },
            height: {
              type: 'number',
              description: 'Window height (optional)',
            },
          },
        },
      },
      {
        name: 'nvim_focus_window',
        description: 'Move focus to a specific window',
        inputSchema: {
          type: 'object',
          properties: {
            winnr: {
              type: 'number',
              description: 'Window number to focus',
            },
          },
          required: ['winnr'],
        },
      },
    ],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case 'nvim_get_buffer': {
        const lines = await callNeovim('buf_get_lines', { bufnr: args?.bufnr });
        return {
          content: [
            {
              type: 'text',
              text: lines.join('\n'),
            },
          ],
        };
      }

      case 'nvim_set_buffer': {
        if (!args || !args.lines) {
          throw new Error('Missing required parameter: lines');
        }
        await callNeovim('buf_set_lines', {
          lines: args.lines,
          bufnr: args.bufnr,
        });
        return {
          content: [
            {
              type: 'text',
              text: 'Buffer updated successfully',
            },
          ],
        };
      }

      case 'nvim_get_info': {
        const info = await callNeovim('get_current_file');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(info, null, 2),
            },
          ],
        };
      }

      case 'nvim_execute': {
        if (!args || !args.command) {
          throw new Error('Missing required parameter: command');
        }
        await callNeovim('execute', { command: args.command });
        return {
          content: [
            {
              type: 'text',
              text: `Executed: ${args.command}`,
            },
          ],
        };
      }

      case 'nvim_list_buffers': {
        const buffers = await callNeovim('list_buffers');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(buffers, null, 2),
            },
          ],
        };
      }

      case 'nvim_get_cursor': {
        const pos = await callNeovim('get_cursor_position');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(pos, null, 2),
            },
          ],
        };
      }

      case 'nvim_set_cursor': {
        if (!args || args.line === undefined) {
          throw new Error('Missing required parameter: line');
        }
        await callNeovim('set_cursor_position', {
          line: args.line,
          col: args.col,
        });
        return {
          content: [
            {
              type: 'text',
              text: `Cursor moved to line ${args.line}`,
            },
          ],
        };
      }

      case 'nvim_get_visual_selection': {
        const selection = await callNeovim('get_visual_selection');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(selection, null, 2),
            },
          ],
        };
      }

      case 'nvim_list_windows': {
        const windows = await callNeovim('list_windows');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(windows, null, 2),
            },
          ],
        };
      }

      case 'nvim_get_window_info': {
        const info = await callNeovim('get_window_info', { winnr: args?.winnr });
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(info, null, 2),
            },
          ],
        };
      }

      case 'nvim_get_window_view': {
        const view = await callNeovim('get_window_view', { winnr: args?.winnr });
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(view, null, 2),
            },
          ],
        };
      }

      case 'nvim_list_tabpages': {
        const tabs = await callNeovim('list_tabpages');
        return {
          content: [
            {
              type: 'text',
              text: JSON.stringify(tabs, null, 2),
            },
          ],
        };
      }

      case 'nvim_set_window_size': {
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
          content: [
            {
              type: 'text',
              text: 'Window size updated successfully',
            },
          ],
        };
      }

      case 'nvim_focus_window': {
        if (!args || args.winnr === undefined) {
          throw new Error('Missing required parameter: winnr');
        }
        await callNeovim('focus_window', { winnr: args.winnr });
        return {
          content: [
            {
              type: 'text',
              text: `Focused window ${args.winnr}`,
            },
          ],
        };
      }

      default:
        return {
          content: [
            {
              type: 'text',
              text: `Unknown tool: ${name}`,
            },
          ],
          isError: true,
        };
    }
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    return {
      content: [
        {
          type: 'text',
          text: `Error: ${errorMessage}`,
        },
      ],
      isError: true,
    };
  }
});

// Start the server
const transport = new StdioServerTransport();
await server.connect(transport);

// Handle process termination
process.on('SIGINT', async () => {
  if (socket) {
    socket.destroy();
  }
  await server.close();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  if (socket) {
    socket.destroy();
  }
  await server.close();
  process.exit(0);
});
