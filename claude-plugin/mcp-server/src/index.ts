#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { callNeovim, closeSocket, RPC_PORT_ENV } from './rpc.js';
import { allTools } from './tools/index.js';
import { withProfiles } from './tools/profiles.js';

// A local socket round trip; long enough for a busy editor, short enough not to stall startup.
const PROFILE_LOOKUP_TIMEOUT_MS = 2000;
import { handlers } from './handlers/index.js';

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

// List available tools.
//
// The configured chat profiles are read from the Neovim this server is bound to, so the model sees
// them in `nvim_chat_create`'s schema (`tools/profiles.ts`). Only when bound: an unbound server
// (registered at user scope, outside vibing.nvim) has no Neovim of its own to ask. Any failure
// falls back to the static list — a tool list that fails to load would take every tool with it.
server.setRequestHandler(ListToolsRequestSchema, async () => {
  if (!process.env[RPC_PORT_ENV]?.trim()) {
    return { tools: allTools };
  }
  try {
    const result = await callNeovim('list_profiles', {}, undefined, PROFILE_LOOKUP_TIMEOUT_MS);
    return { tools: withProfiles(allTools, result?.profiles ?? []) };
  } catch {
    return { tools: allTools };
  }
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    const handler = handlers[name];
    if (handler) {
      return await handler(args);
    }

    return {
      content: [{ type: 'text', text: `Unknown tool: ${name}` }],
      isError: true,
    };
  } catch (err) {
    const errorMessage = err instanceof Error ? err.message : String(err);
    return {
      content: [{ type: 'text', text: `Error: ${errorMessage}` }],
      isError: true,
    };
  }
});

// Start the server
const transport = new StdioServerTransport();
await server.connect(transport);

// Handle process termination
process.on('SIGINT', async () => {
  closeSocket();
  await server.close();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  closeSocket();
  await server.close();
  process.exit(0);
});
