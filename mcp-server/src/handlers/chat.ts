import { callNeovim } from '../rpc.js';
import { z } from 'zod';

// Zod schemas for validation
const chatSendMessageArgsSchema = z.object({
  bufnr: z.number(),
  message: z.string(),
  sender: z.string().optional(),
  rpc_port: z.number(),
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
  chat_bufnr: z.number(),
  questions: z.array(z.any()),
  rpc_port: z.number(),
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
 * `chat_bufnr` and `rpc_port` correlate the call to the right chat buffer/Neovim instance when
 * multiple are active concurrently. They are tool arguments rather than env lookups because env
 * can't carry them here — see `resolveRpcPort` in `../rpc.ts`. Both stay required: this tool kills
 * the in-flight turn, so it is one of the write-side tools that must name its target rather than
 * fall back to the registry (see `requireRpcPort` in `../tools/common.ts`).
 * `chat_bufnr` (unlike a per-turn handle_id) is stable across turns of the same conversation,
 * so it doesn't defeat Anthropic's prompt cache — see issue #469. It is the buffer number rather
 * than the chat file path because `:VibingSetFileTitle` renames the file mid-conversation, which
 * would change the system prompt and invalidate that cache — see issue #489.
 */
export async function handleAskUserQuestion(args: any): Promise<any> {
  const { chat_bufnr, questions, rpc_port } = askUserQuestionArgsSchema.parse(args);

  const result = await callNeovim('ask_user_question', { chat_bufnr, questions }, rpc_port);

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
