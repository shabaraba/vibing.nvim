import { z } from 'zod';
import { callNeovim } from '../rpc.js';

/**
 * Restated from `wait_budget.prompt_tool_wait_sec()` at its default (900 + 60 + 30), for a server
 * started without the variable: Neovim always binds it, so this is reached only by hand.
 */
const DEFAULT_WAIT_SEC = 990;

const promptSchema = z.object({
  tool_name: z.string(),
  input: z.record(z.string(), z.unknown()).default({}),
  tool_use_id: z.string().optional(),
  rpc_port: z.number().optional(),
});

/** How long to wait for Neovim, read from the variable `wait_budget.bind` writes. */
export function promptWaitMs(env: NodeJS.ProcessEnv = process.env): number {
  const seconds = Number(env.VIBING_PROMPT_TOOL_WAIT_SEC);
  return (Number.isFinite(seconds) && seconds > 0 ? seconds : DEFAULT_WAIT_SEC) * 1000;
}

function answer(body: Record<string, unknown>) {
  return { content: [{ type: 'text', text: JSON.stringify(body) }] };
}

function deny(message: string) {
  return answer({ behavior: 'deny', message });
}

/**
 * Answer one question claude's own gate asked, in the shape `--permission-prompt-tool` expects:
 * `{behavior:"allow", updatedInput}` runs the call, `{behavior:"deny", message}` refuses it.
 *
 * **Every failure denies.** An error result here is not a refusal the CLI understands, and the
 * call the human never saw must not run, so a malformed request, an RPC error and the deadline all
 * end in `deny`.
 */
export async function handlePermissionPrompt(args: unknown) {
  const parsed = promptSchema.safeParse(args);
  if (!parsed.success) {
    return deny('vibing.nvim received a malformed permission prompt.');
  }
  const { tool_name, input, tool_use_id, rpc_port } = parsed.data;

  let result: { decision?: string; message?: string } | undefined;
  try {
    result = await callNeovim(
      'permission_prompt',
      { process_id: process.env.VIBING_PROCESS_ID ?? '', tool_name, input, tool_use_id },
      rpc_port,
      promptWaitMs()
    );
  } catch (err) {
    const reason = err instanceof Error ? err.message : String(err);
    return deny(`vibing.nvim could not ask about ${tool_name} (${reason}), so it was refused.`);
  }

  if (result?.decision === 'allow') {
    return answer({ behavior: 'allow', updatedInput: input });
  }
  return deny(result?.message ?? `vibing.nvim refused ${tool_name}.`);
}
