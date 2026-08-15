#!/usr/bin/env node
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { CallToolRequestSchema, ListToolsRequestSchema } from '@modelcontextprotocol/sdk/types.js';
import { closeSocket } from './rpc.js';
import { allTools } from './tools/index.js';
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

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return { tools: allTools };
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
