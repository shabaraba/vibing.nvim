import { callNeovim } from '../rpc.js';
import { z } from 'zod';

// Zod schemas for validation
const chatSendMessageArgsSchema = z.object({
  bufnr: z.number(),
  message: z.string(),
  sender: z.string().optional(),
  rpc_port: z.number().optional(),
});

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const { bufnr, message, sender, rpc_port } = chatSendMessageArgsSchema.parse(args);

  await callNeovim('send_message', { bufnr, message, sender }, rpc_port);

  return {
    content: [{ type: 'text', text: 'Message sent and AI request initiated in chat buffer' }],
    _meta: { bufnr, sender: sender || 'User' },
  };
}

/**
 * Handler for nvim_ask_user_question
 *
 * In normal operation, vibing.nvim's PreToolUse hook (see
 * `lua/vibing/infrastructure/rpc/handlers/permission.lua`) intercepts this tool call before it
 * executes, cancels the request, and renders the questions as an editable choice list in the
 * chat buffer instead. This handler only runs if that interception did not happen (e.g. hooks
 * misconfigured), and exists purely as a defensive fallback.
 */
export async function handleAskUserQuestion(_args: any): Promise<any> {
  return {
    content: [
      {
        type: 'text',
        text: 'nvim_ask_user_question was not intercepted by the vibing.nvim permission hook. Ask the question as plain text instead.',
      },
    ],
    isError: true,
  };
}
