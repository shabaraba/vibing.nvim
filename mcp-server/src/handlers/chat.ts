import { callNeovim } from '../rpc.js';
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
  squad_name: z.string().optional(),
  rpc_port: z.number().optional(),
});

const replyToMentionArgsSchema = z.object({
  to_squad_name: z.string(),
  message: z.string(),
  rpc_port: z.number().optional(),
});

const reportToSquadArgsSchema = z.object({
  to_squad_name: z.string(),
  message: z.string(),
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
 * Internal helper: Send message to a chat buffer
 * Used by both handleChatSendMessage and the new squad communication handlers
 */
async function sendMessageToBuffer(
  bufnr: number,
  message: string,
  sender: string | undefined,
  squad_name: string | undefined,
  rpc_port: number | undefined
): Promise<void> {
  await callNeovim('send_message', { bufnr, message, sender, squad_name }, rpc_port);
}

/**
 * Internal helper: Find buffer number for a squad
 */
async function findSquadBuffer(squad_name: string, rpc_port: number | undefined): Promise<number> {
  const result = await callNeovim('find_squad_buffer', { squad_name }, rpc_port);

  if (!result || result.bufnr === null) {
    throw new Error(`Squad "${squad_name}" not found`);
  }

  return result.bufnr;
}

/**
 * Internal helper: Get current squad name
 */
async function getCurrentSquadName(rpc_port: number | undefined): Promise<string> {
  const info = await callNeovim('get_squad_info', { bufnr: 0 }, rpc_port);

  if (!info || !info.squad_name) {
    throw new Error('Cannot determine current squad name');
  }

  return info.squad_name;
}

/**
 * Handler for nvim_chat_send_message
 * Programmatically sends a message to a chat buffer and triggers AI request
 * NOTE: This is now an internal tool, not exposed via MCP
 */
export async function handleChatSendMessage(args: any): Promise<any> {
  // Zod schema already validates required fields and types
  const { bufnr, message, sender, squad_name, rpc_port } = chatSendMessageArgsSchema.parse(args);

  await sendMessageToBuffer(bufnr, message, sender, squad_name, rpc_port);

  return {
    content: [{ type: 'text', text: 'Message sent and AI request initiated in chat buffer' }],
    _meta: { bufnr, sender: sender || 'User', squad_name },
  };
}

/**
 * Handler for nvim_reply_to_mention
 * Reply to a mention from another squad
 */
export async function handleReplyToMention(args: any): Promise<any> {
  const { to_squad_name, message, rpc_port } = replyToMentionArgsSchema.parse(args);

  // Get current squad name (the sender)
  const from_squad_name = await getCurrentSquadName(rpc_port);

  // Find target squad's buffer
  const target_bufnr = await findSquadBuffer(to_squad_name, rpc_port);

  // Send reply with mention_response header
  await sendMessageToBuffer(target_bufnr, message, 'mention_response', from_squad_name, rpc_port);

  return {
    content: [
      {
        type: 'text',
        text: `Reply sent to ${to_squad_name} (buffer ${target_bufnr}) from ${from_squad_name}`,
      },
    ],
    _meta: { to_squad_name, from_squad_name, target_bufnr },
  };
}

/**
 * Handler for nvim_report_to_squad
 * Report progress or results to another squad
 */
export async function handleReportToSquad(args: any): Promise<any> {
  const { to_squad_name, message, rpc_port } = reportToSquadArgsSchema.parse(args);

  // Get current squad name (the sender)
  const from_squad_name = await getCurrentSquadName(rpc_port);

  // Find target squad's buffer
  const target_bufnr = await findSquadBuffer(to_squad_name, rpc_port);

  // Send report with mention_response header (same as reply)
  await sendMessageToBuffer(target_bufnr, message, 'mention_response', from_squad_name, rpc_port);

  return {
    content: [
      {
        type: 'text',
        text: `Report sent to ${to_squad_name} (buffer ${target_bufnr}) from ${from_squad_name}`,
      },
    ],
    _meta: { to_squad_name, from_squad_name, target_bufnr },
  };
}
