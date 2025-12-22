#!/usr/bin/env node
/**
 * Neovim MCP Server for Claude Agent SDK
 * Provides tools to interact with a remote Neovim instance via socket
 */

import { tool, createSdkMcpServer } from '@anthropic-ai/claude-agent-sdk';
import { attach } from 'neovim';
import { z } from 'zod';

/**
 * Create an in-process MCP server for Neovim operations
 * @param {string} socketPath - Path to Neovim socket (from $NVIM or --listen)
 * @returns {object} MCP server instance
 */
export function createNeovimMcpServer(socketPath) {
  if (!socketPath) {
    throw new Error('Neovim socket path is required. Start Neovim with --listen or set $NVIM');
  }

  let nvimClient = null;

  /**
   * Get or create Neovim client connection
   */
  async function getNvimClient() {
    // Check if existing connection is still healthy
    if (nvimClient) {
      try {
        await nvimClient.getApiInfo();
        return nvimClient;
      } catch (error) {
        console.error('Existing connection is stale, reconnecting...');
        nvimClient = null;
      }
    }

    // Create new connection
    try {
      nvimClient = attach({ socket: socketPath });
      // Verify connection works
      await nvimClient.getApiInfo();
      return nvimClient;
    } catch (error) {
      throw new Error(`Failed to connect to Neovim at ${socketPath}: ${error.message}`);
    }
  }

  /**
   * Close Neovim client connection
   */
  function cleanup() {
    if (nvimClient) {
      try {
        nvimClient.quit();
      } catch (e) {
        // Ignore cleanup errors
      }
      nvimClient = null;
    }
  }

  // Define tools using the tool() function
  const nvimBufGetLines = tool(
    'buf_get_lines',
    'Get lines from current Neovim buffer',
    {
      start: z.number().optional().default(0).describe('Start line (0-indexed, -1 for end)'),
      end: z.number().optional().default(-1).describe('End line (0-indexed, -1 for end)'),
    },
    async (args) => {
      const nvim = await getNvimClient();
      const buffer = await nvim.buffer;
      const lines = await buffer.getLines({
        start: args.start,
        end: args.end,
        strictIndexing: false,
      });
      return {
        content: [{ type: 'text', text: lines.join('\n') }],
      };
    }
  );

  const nvimBufSetLines = tool(
    'buf_set_lines',
    'Set lines in current Neovim buffer',
    {
      start: z.number().describe('Start line (0-indexed)'),
      end: z.number().describe('End line (0-indexed, -1 for end)'),
      lines: z.array(z.string()).describe('Lines to set'),
    },
    async (args) => {
      try {
        const nvim = await getNvimClient();
        const buffer = await nvim.buffer;
        await buffer.setLines(args.lines, {
          start: args.start,
          end: args.end,
          strictIndexing: false,
        });
        return {
          content: [
            {
              type: 'text',
              text: `Successfully set ${args.lines.length} lines from ${args.start} to ${args.end}`,
            },
          ],
        };
      } catch (error) {
        throw new Error(`Failed to set buffer lines: ${error.message}`);
      }
    }
  );

  // Allowed Ex commands for security
  const ALLOWED_COMMANDS = [
    'write',
    'w',
    'quit',
    'q',
    'wq',
    'wa',
    'wqa',
    'qa',
    'edit',
    'e',
    'enew',
    'new',
    'vnew',
    'buffer',
    'b',
    'bnext',
    'bn',
    'bprevious',
    'bp',
    'bfirst',
    'blast',
    'bdelete',
    'bd',
    'split',
    'sp',
    'vsplit',
    'vs',
    'close',
    'tabnew',
    'tabnext',
    'tabprevious',
    'tabclose',
    'normal',
    'set',
    'setlocal',
  ];

  const nvimCommand = tool(
    'command',
    'Execute Ex command in Neovim (restricted to safe commands)',
    {
      command: z.string().describe('Ex command to execute (without leading colon)'),
    },
    async (args) => {
      // Extract base command (first word)
      const baseCmd = args.command.trim().split(/\s+/)[0];

      // Block dangerous patterns
      if (/^(!|source|py|py3|python|python3|lua|ruby|perl|mzscheme)/.test(baseCmd)) {
        throw new Error(
          `Command '${baseCmd}' is not allowed for security reasons. ` +
            `Shell execution and script sourcing are prohibited.`
        );
      }

      // Check if command is in allowed list
      if (!ALLOWED_COMMANDS.includes(baseCmd)) {
        throw new Error(
          `Command '${baseCmd}' is not in the allowed list. ` +
            `Allowed commands: ${ALLOWED_COMMANDS.join(', ')}`
        );
      }

      try {
        const nvim = await getNvimClient();
        await nvim.command(args.command);
        return {
          content: [{ type: 'text', text: `Executed: ${args.command}` }],
        };
      } catch (error) {
        throw new Error(`Failed to execute command '${args.command}': ${error.message}`);
      }
    }
  );

  const nvimGetStatus = tool(
    'get_status',
    'Get current Neovim status (mode, buffer, cursor position)',
    {},
    async () => {
      const nvim = await getNvimClient();
      const mode = await nvim.mode;
      const buffer = await nvim.buffer;
      const bufferName = await buffer.name;
      const window = await nvim.window;
      const cursor = await window.cursor;

      const status = {
        mode: mode.mode,
        buffer: bufferName,
        line: cursor[0],
        col: cursor[1],
      };

      return {
        content: [
          {
            type: 'text',
            text: JSON.stringify(status, null, 2),
          },
        ],
      };
    }
  );

  // Create and return the MCP server
  return createSdkMcpServer({
    name: 'neovim',
    version: '1.0.0',
    tools: [nvimBufGetLines, nvimBufSetLines, nvimCommand, nvimGetStatus],
  });
}
