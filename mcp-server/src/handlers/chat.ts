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
  handle_id: z.string(),
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
 * `handle_id` and `rpc_port` correlate the call to the right chat buffer/Neovim instance when
 * multiple are active concurrently. Both are required tool arguments rather than sourced from env
 * vars: the MCP client (per the `@modelcontextprotocol/sdk` stdio transport) only forwards a fixed
 * OS-level env whitelist plus whatever is statically configured in the server's registration (see
 * `.claude-plugin/plugin.json`), so per-turn/per-instance values set on the parent `claude` CLI
 * process's env can never reach this MCP server subprocess. Instead, `cli_command_builder.lua`
 * embeds the real values into the turn's system prompt and instructs the model to echo them back
 * here.
 */
export async function handleAskUserQuestion(args: any): Promise<any> {
  const { handle_id, questions, rpc_port } = askUserQuestionArgsSchema.parse(args);

  const result = await callNeovim('ask_user_question', { handle_id, questions }, rpc_port);

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
