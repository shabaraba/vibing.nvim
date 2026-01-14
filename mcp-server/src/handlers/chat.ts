import { callNeovim } from '../rpc.js';
import { validateRequired, validateBufferParams } from '../validation/schema.js';
import { z } from 'zod';

// Zod schemas for validation
const chatWorktreeArgsSchema = z.object({
  branch_name: z.string(),
  position: z.enum(['current', 'right', 'left', 'top', 'bottom', 'back']).optional(),
  rpc_port: z.number().optional(),
});

const chatSendMessageArgsSchema = z.object({
  bufnr: z.number(),
  message: z.string(),
  sender: z.string().optional(),
  rpc_port: z.number().optional(),
});

/**
 * Handler for nvim_chat_worktree
 * Creates or reuses a git worktree and opens a chat session in that environment
 */
export async function handleChatWorktree(args: unknown): Promise<any> {
  const { branch_name, position, rpc_port } = chatWorktreeArgsSchema.parse(args);

  // Build VibingChatWorktree command
  const command = position
    ? `VibingChatWorktree ${position} ${branch_name}`
    : `VibingChatWorktree ${branch_name}`;

  const result = await callNeovim('execute', { command }, rpc_port);

  const output = result?.output?.trim() || '';
  const message = output
    ? `Worktree chat opened:\n${output}`
    : `Worktree chat opened for branch: ${branch_name}`;

  return {
    content: [{ type: 'text', text: message }],
  };
}

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Validate required parameters
  validateRequired(args?.bufnr, 'bufnr');
  validateRequired(args?.message, 'message');
  validateBufferParams({ bufnr: args.bufnr });

  const { bufnr, message, sender, rpc_port } = chatSendMessageArgsSchema.parse(args);

  await callNeovim('send_message', { bufnr, message, sender }, rpc_port);

  return {
    content: [{ type: 'text', text: 'Message sent and AI request initiated in chat buffer' }],
    _meta: { bufnr, sender: sender || 'User' },
  };
}
