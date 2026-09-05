import { callNeovim } from '../rpc.js';
import { z } from 'zod';
import { APPROVAL_ACTIONS, CHAT_POSITIONS } from '../tools/chat.js';
import { validateChatTarget } from '../validation/schema.js';

// `task` is written into the caller's own `orchestrated` entry as `<path>|<task>`
// (orchestrated_entry.lua). A newline would let the value smuggle extra frontmatter lines past
// the encoding on any write path that is not guarded by nvim_buf_set_lines' own line-break
// rejection (the disk-direct rename-sync path in frontmatter_file.lua is not) -- reject it here,
// at the boundary, rather than relying on that guard alone.
const taskSchema = z
  .string()
  .refine((value) => !/[\r\n]/.test(value), { message: 'task must not contain line breaks' })
  .optional();

const chatCreateArgsSchema = z.object({
  position: z.enum(CHAT_POSITIONS).optional(),
  working_dir: z.string().optional(),
  from_bufnr: z.number().optional(),
  task: taskSchema,
  delegated_scope: z.array(z.string()).optional(),
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
 *
 * `task` is written on the CALLER's own frontmatter (next to the `from_bufnr` link), not on the
 * new chat — see `orchestrated_entry.lua`. Passing `task` without `from_bufnr` has nowhere to go
 * and the Lua side drops it with a warning rather than silently discarding it.
 *
 * `delegated_scope` is the opposite of `task`: it is written on the NEW chat's OWN frontmatter
 * (`delegated_scope`, same pattern syntax as `permissions_allow`), because it is
 * `approval_delegate.lua`'s "scoped" mode reading the answering chat's own declaration, not
 * something that belongs to whoever created it. It has no effect unless
 * `agent.orchestration.delegated_approval` is `"scoped"`.
 */
export async function handleChatCreate(args: any): Promise<any> {
  const { position, working_dir, from_bufnr, task, delegated_scope, rpc_port } =
    chatCreateArgsSchema.parse(args);

  const result = await callNeovim(
    'create_chat',
    { position, working_dir, from_bufnr, task, delegated_scope },
    rpc_port
  );

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
  task: taskSchema,
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
 *
 * `task` replaces the one-line assignment recorded on the CALLER's own frontmatter for this
 * target (see `nvim_chat_create`'s `task`), so an orchestrator can keep that summary current as
 * the work evolves. Same `from_bufnr` requirement as `nvim_chat_create`'s `task`; omitted, an
 * ordinary follow-up leaves the existing assignment untouched.
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const parsed = chatSendMessageArgsSchema.parse(args);
  const { message, sender, from_bufnr, queue_if_busy, task, rpc_port } = parsed;
  // Collapse an explicit null to "not given" once, here, so nothing downstream has to know the
  // difference — including the Lua side, where a JSON null decodes to the truthy vim.NIL.
  const bufnr = parsed.bufnr ?? undefined;
  const file_path = parsed.file_path ?? undefined;

  // Sending starts a turn in someone else's chat, so unlike a read it has nothing to fall back to.
  validateChatTarget({ bufnr, file_path }, { required: true });

  const result = await callNeovim(
    'send_message',
    { bufnr, file_path, message, sender, from_bufnr, queue_if_busy, task },
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

const chatAnswerApprovalArgsSchema = z.object({
  bufnr: z.number().nullish(),
  file_path: z.string().nullish(),
  action: z.enum(APPROVAL_ACTIONS),
  from_bufnr: z.number(),
  rpc_port: z.number(),
});

/**
 * Handler for nvim_chat_answer_approval
 *
 * A chat that hit a tool in its `ask` list has had its turn killed and the approval prompt drawn
 * into its buffer (`rpc/handlers/permission.lua`). It cannot continue, and it cannot report that
 * it is stuck — so until someone answers, it simply never moves again. By default that someone is
 * the user; `agent.orchestration.delegated_approval` lets an orchestrator stand in — fully when
 * it is `true`, or only for tools within the target chat's own declared `delegated_scope` when
 * it is `"scoped"` (a denial always goes through either way).
 *
 * The gate lives on the Lua side rather than here, so the model gets one answer whichever route
 * it takes and the setting cannot be read stale by a server process that started before it
 * changed. That is also why a disabled or out-of-scope call comes back as an error with the
 * wording the model should act on ("tell the user which chat is blocked") instead of a bare
 * refusal.
 *
 * `from_bufnr` is required here although the other chat tools keep it optional: this call removes
 * a permission gate, and one that cannot record whose decision it was should not be made at all.
 * Version skew is not an argument for softening it — a Neovim without the `answer_approval` RPC
 * method rejects the call outright.
 */
export async function handleChatAnswerApproval(args: any): Promise<any> {
  const parsed = chatAnswerApprovalArgsSchema.parse(args);
  const { action, from_bufnr, rpc_port } = parsed;
  const bufnr = parsed.bufnr ?? undefined;
  const file_path = parsed.file_path ?? undefined;

  validateChatTarget({ bufnr, file_path }, { required: true });

  const result = await callNeovim(
    'answer_approval',
    { bufnr, file_path, action, from_bufnr },
    rpc_port
  );

  return {
    content: [
      {
        type: 'text',
        text:
          `Answered ${result?.tool ?? 'the'} tool approval with ${action}. That chat has started ` +
          'a new turn; it will come back to you when it stops.',
      },
    ],
    _meta: { bufnr: result?.bufnr ?? bufnr, tool: result?.tool, action },
  };
}

/**
 * Handler for nvim_chat_list
 *
 * Enumerates every chat buffer `view.list_chat_buffers()` knows about on the Lua side — the same
 * source `application/chat/concurrency.lua` reads to answer "how many chats are responding right
 * now" — and reports each one's status in a single round trip. A read, so `rpc_port` stays
 * optional and falls back to the instance registry like `nvim_list_buffers`.
 */
export async function handleChatList(args: any): Promise<any> {
  const result = await callNeovim('list_chats', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}

/**
 * Handler for nvim_chat_conflicts
 *
 * A read, like nvim_chat_list: rpc_port stays optional and falls back to the instance registry.
 * The Lua side (`chat_conflicts` in `rpc/handlers/chat.lua`) does all the work — enumerating
 * live chats, resolving each one's `working_dir` to a worktree, diffing it against main/master,
 * and grouping the results by file. This handler only forwards the call and the JSON back.
 */
export async function handleChatConflicts(args: any): Promise<any> {
  const result = await callNeovim('chat_conflicts', {}, args?.rpc_port);
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
  };
}
