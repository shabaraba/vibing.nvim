import type { Tool } from '@modelcontextprotocol/sdk/types.js';

/**
 * Chat-related MCP tools
 */

export const chatTools: Tool[] = [
  {
    name: 'nvim_chat_worktree',
    description:
      'Create or reuse git worktree and open chat session in that environment. ' +
      'Equivalent to :VibingChatWorktree command. ' +
      'Automatically handles worktree creation, config file copying, and node_modules symlinking.',
    inputSchema: {
      type: 'object',
      properties: {
        branch_name: {
          type: 'string',
          description: 'Branch name for the worktree (e.g., "feature-xyz")',
        },
        position: {
          type: 'string',
          description:
            'Optional window position: "current", "right", "left", "top", "bottom", or "back"',
          enum: ['current', 'right', 'left', 'top', 'bottom', 'back'],
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of target Neovim instance (optional, defaults to 9876). Use nvim_list_instances to discover available instances.',
        },
      },
      required: ['branch_name'],
    },
  },
  {
    name: 'nvim_reply_to_mention',
    description:
      'Reply to a mention from another squad. ' +
      'Use this when you received a mention (e.g., "@Alpha please review this") and want to send your response back to the sender\'s chat buffer. ' +
      'The message will appear with a "Mention response from <YourSquadName>" header.',
    inputSchema: {
      type: 'object',
      properties: {
        to_squad_name: {
          type: 'string',
          description: 'Name of the squad to reply to (e.g., "Alpha", "Commander")',
        },
        message: {
          type: 'string',
          description: 'Your reply message content',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of your Neovim instance (optional, defaults to 9876). IMPORTANT: Use your own instance port, not another instance.',
        },
      },
      required: ['to_squad_name', 'message'],
    },
  },
  {
    name: 'nvim_report_to_squad',
    description:
      "Report progress, results, or findings to another squad's chat buffer. " +
      'Use this to notify completion, share analysis results, or provide status updates. ' +
      'The message will appear with a "Mention response from <YourSquadName>" header.',
    inputSchema: {
      type: 'object',
      properties: {
        to_squad_name: {
          type: 'string',
          description: 'Name of the squad to send the report to (e.g., "Commander", "Alpha")',
        },
        message: {
          type: 'string',
          description: 'Report content (progress update, findings, completion notice, etc.)',
        },
        rpc_port: {
          type: 'number',
          description:
            'RPC port of your Neovim instance (optional, defaults to 9876). IMPORTANT: Use your own instance port, not another instance.',
        },
      },
      required: ['to_squad_name', 'message'],
    },
  },
];
