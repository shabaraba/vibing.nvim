import { z } from 'zod';
import { callNeovim } from '../rpc.js';

/**
 * Handlers for the queued prompt tools.
 *
 * `VIBING_PROCESS_ID` is what lets Neovim resolve the calling turn (`rpc/hook_scope.lua`): the same
 * id `nvim_permission_prompt` sends. A server launched without it — a user-scope registration, or a
 * backend whose transport does not forward it — is refused by Neovim rather than shown in whichever
 * chat happens to be streaming.
 */

const optionSchema = z.object({
  label: z.string().min(1),
  description: z.string().optional(),
});

const questionSchema = z.object({
  question: z.string().optional(),
  multiSelect: z.boolean().optional(),
  options: z.array(optionSchema).min(1),
});

const askSchema = z.object({
  questions: z.array(questionSchema).min(1).max(4),
  rpc_port: z.number().optional(),
});

const approvalSchema = z.object({
  reason: z.string().min(1),
  tool: z.string().optional(),
  input: z.record(z.string(), z.unknown()).optional(),
  rpc_port: z.number().optional(),
});

type ToolResult = {
  content: { type: 'text'; text: string }[];
  isError?: boolean;
};

function answer(message: string, isError = false): ToolResult {
  return isError
    ? { content: [{ type: 'text', text: message }], isError: true }
    : { content: [{ type: 'text', text: message }] };
}

async function queue(
  method: string,
  params: Record<string, unknown>,
  rpcPort: number | undefined
): Promise<ToolResult> {
  try {
    const result = await callNeovim(
      method,
      { process_id: process.env.VIBING_PROCESS_ID ?? '', ...params },
      rpcPort
    );
    return answer(result?.message ?? 'vibing.nvim queued it.', result?.ok !== true);
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return answer(`vibing.nvim could not queue this call (${reason}).`, true);
  }
}

export async function handleAskQuestion(args: unknown): Promise<ToolResult> {
  const parsed = askSchema.safeParse(args);
  if (!parsed.success) {
    return answer('vibing.nvim did not queue this question: its arguments are malformed.', true);
  }
  const { questions, rpc_port } = parsed.data;
  return queue('ask_question', { questions }, rpc_port);
}

export async function handleRequestApproval(args: unknown): Promise<ToolResult> {
  const parsed = approvalSchema.safeParse(args);
  if (!parsed.success) {
    return answer(
      'vibing.nvim did not queue this confirmation: it needs a non-empty reason.',
      true
    );
  }
  const { reason, tool, input, rpc_port } = parsed.data;
  return queue('request_approval', { reason, tool, input }, rpc_port);
}
