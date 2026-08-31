import { callNeovim } from '../rpc.js';
import { z } from 'zod';
import { CHAT_POSITIONS } from '../tools/chat.js';

const chatCreateArgsSchema = z.object({
  position: z.enum(CHAT_POSITIONS).optional(),
  working_dir: z.string().optional(),
  from_bufnr: z.number().optional(),
  rpc_port: z.number(),
});

/**
 * Handler for nvim_chat_create
 *
 * Creates a chat buffer the caller can then drive with `nvim_chat_send_message`. The result is
 * JSON rather than prose because the orchestrator has to carry `bufnr` forward across turns —
 * it is the only handle to a worker chat, and a `back` chat has no window to find it by.
 *
 * The chat file is written to disk by the Lua handler at creation time, so `file_path` names a
 * file that actually exists; `saved: false` means that write failed and the chat lives only in
 * the buffer.
 *
 * `from_bufnr` is optional and records the caller as this chat's orchestrator in both chat files'
 * frontmatter. It stays optional deliberately: making it required would break every existing
 * caller that omits it, and there is no protocol version on the wire — an older Neovim simply
 * ignores the extra key, and an older server never sends it.
 */
export async function handleChatCreate(args: any): Promise<any> {
  const { position, working_dir, from_bufnr, rpc_port } = chatCreateArgsSchema.parse(args);

  const result = await callNeovim('create_chat', { position, working_dir, from_bufnr }, rpc_port);

  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    _meta: { bufnr: result?.bufnr, file_path: result?.file_path },
  };
}

// Zod schemas for validation
const chatSendMessageArgsSchema = z.object({
  bufnr: z.number(),
  message: z.string(),
  sender: z.string().optional(),
  from_bufnr: z.number().optional(),
  rpc_port: z.number(),
});

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 *
 * `from_bufnr` names the calling chat and records the orchestration relationship in both chat
 * files' frontmatter, so it outlives the buffer numbers and the file names it was built from.
 * It is optional for compatibility in both directions of Lua/Node version skew: an older Neovim
 * ignores the extra key, an older server never sends it, and neither breaks the send.
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const { bufnr, message, sender, from_bufnr, rpc_port } = chatSendMessageArgsSchema.parse(args);

  await callNeovim('send_message', { bufnr, message, sender, from_bufnr }, rpc_port);

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
