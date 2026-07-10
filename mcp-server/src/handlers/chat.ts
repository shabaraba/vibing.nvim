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

const askUserQuestionArgsSchema = z.object({
  questions: z.array(z.any()),
  rpc_port: z.number().optional(),
});

/**
 * Handler for nvim_ask_user_question
 *
 * Unlike a normal MCP tool, this does not return a real answer as its tool_result. It calls
 * `ask_user_question` on the Neovim RPC server (see
 * `lua/vibing/infrastructure/rpc/handlers/permission.lua`), which renders the questions as an
 * editable choice list in the chat buffer and then immediately cancels/kills the current turn —
 * so this handler's return value is never actually seen by the model. The user's next message in
 * that buffer (a fresh `--resume`d turn) IS the answer to this call.
 *
 * `handle_id` correlates the call to the right chat buffer when multiple chats are active
 * concurrently; it comes from the `VIBING_HANDLE_ID` env var vibing.nvim sets on this MCP
 * server's own process (inherited from the `claude` CLI process that spawned it), not from the
 * model — it has no legitimate way to know this value.
 */
export async function handleAskUserQuestion(args: any): Promise<any> {
  const { questions, rpc_port } = askUserQuestionArgsSchema.parse(args);
  const handleId = process.env.VIBING_HANDLE_ID;

  const result = await callNeovim(
    'ask_user_question',
    { handle_id: handleId, questions },
    rpc_port
  );

  if (result?.status !== 'ok') {
    return {
      content: [
        {
          type: 'text',
          text: result?.reason || 'Failed to present the question in the vibing.nvim chat buffer.',
        },
      ],
      isError: true,
    };
  }

  return {
    content: [{ type: 'text', text: 'Question presented to the user in the chat buffer.' }],
  };
}
