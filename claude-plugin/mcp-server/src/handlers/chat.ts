import { callNeovim } from '../rpc.js';
import { z } from 'zod';
import { CHAT_POSITIONS } from '../tools/chat.js';
import { validateChatTarget } from '../validation/schema.js';

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
//
// `nullish` rather than `optional` on the two target arguments: a model that spells the one it is
// not using as an explicit `null` should get the ordinary "name it once" handling from
// validateChatTarget, not a type error naming a field it deliberately left empty.
const chatSendMessageArgsSchema = z.object({
  bufnr: z.number().nullish(),
  file_path: z.string().nullish(),
  message: z.string(),
  sender: z.string().optional(),
  from_bufnr: z.number().optional(),
  queue_if_busy: z.boolean().optional(),
  rpc_port: z.number(),
});

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 *
 * The target is named by `file_path` or `bufnr`. `file_path` is the one that survives a Neovim
 * restart — a bufnr from a previous session points at some unrelated buffer, while the path is
 * what the chats record in their own frontmatter — and the Lua side opens the chat if it is
 * closed (see `application/chat/chat_locator.lua`). `bufnr` stays accepted: it is what an
 * orchestrator already has in hand for a worker it created this session.
 *
 * `from_bufnr` names the calling chat and records the orchestration relationship in both chat
 * files' frontmatter, so it outlives the buffer numbers and the file names it was built from.
 * It is optional for compatibility in both directions of Lua/Node version skew: an older Neovim
 * ignores the extra key, an older server never sends it, and neither breaks the send.
 *
 * `queue_if_busy` is optional for the same reason, and defaults to off on both sides: an older
 * Neovim ignores it and refuses a busy chat exactly as before, which is the behaviour a caller
 * that did not ask to queue already expects. The reply distinguishes the two outcomes, because
 * "queued" means no turn has started yet — an orchestrator that read it as "sent" would go on to
 * poll a transcript that has not moved.
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const parsed = chatSendMessageArgsSchema.parse(args);
  const { message, sender, from_bufnr, queue_if_busy, rpc_port } = parsed;
  // Collapse an explicit null to "not given" once, here, so nothing downstream has to know the
  // difference — including the Lua side, where a JSON null decodes to the truthy vim.NIL.
  const bufnr = parsed.bufnr ?? undefined;
  const file_path = parsed.file_path ?? undefined;

  // Sending starts a turn in someone else's chat, so unlike a read it has nothing to fall back to.
  validateChatTarget({ bufnr, file_path }, { required: true });

  const result = await callNeovim(
    'send_message',
    { bufnr, file_path, message, sender, from_bufnr, queue_if_busy },
    rpc_port
  );

  const queued = result?.queued === true;

  return {
    content: [
      {
        type: 'text',
        text: queued
          ? 'That chat is responding right now, so the message was queued. It will be delivered ' +
            'as a new turn as soon as that chat stops — no request has started yet.'
          : 'Message sent and AI request initiated in chat buffer',
      },
    ],
    // The Lua side resolved file_path to a buffer, so report what it actually reached rather than
    // echoing an argument that may have been a path.
    _meta: { bufnr: result?.bufnr ?? bufnr, sender: sender || 'User', queued },
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
