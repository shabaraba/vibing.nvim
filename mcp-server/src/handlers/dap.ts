import { callNeovim } from '../rpc.js';
import { validateFilePath } from '../validation/schema.js';
import { z } from 'zod';

/**
 * Handlers for the nvim_dap_* tools.
 *
 * Nothing here knows whether nvim-dap is installed or stopped — `handlers/dap.lua` answers that,
 * either as `{ running = false, reason = ... }` from get_state or as an error the model reads.
 * This layer only rejects arguments that could not work at all, before touching Neovim.
 */

// Every dap tool targets exactly one debug session, so rpc_port is the one shared requirement.
const baseArgsSchema = z.object({ rpc_port: z.number() });

const stackTraceArgsSchema = baseArgsSchema.extend({ thread_id: z.number().int().optional() });
const variablesArgsSchema = baseArgsSchema.extend({ frame_id: z.number().int().optional() });
const evaluateArgsSchema = baseArgsSchema.extend({
  expression: z.string().min(1),
  frame_id: z.number().int().optional(),
});
const setBreakpointArgsSchema = baseArgsSchema.extend({
  file: z.string().min(1),
  line: z.number().int().positive(),
  condition: z.string().optional(),
});

function asJson(result: unknown) {
  return {
    content: [{ type: 'text', text: JSON.stringify(result, null, 2) }],
    _meta: result,
  };
}

export async function handleDapGetState(args: any): Promise<any> {
  const { rpc_port } = baseArgsSchema.parse(args);
  return asJson(await callNeovim('dap_get_state', {}, rpc_port));
}

export async function handleDapGetStackTrace(args: any): Promise<any> {
  const { thread_id, rpc_port } = stackTraceArgsSchema.parse(args);
  return asJson(await callNeovim('dap_get_stack_trace', { thread_id }, rpc_port));
}

export async function handleDapGetVariables(args: any): Promise<any> {
  const { frame_id, rpc_port } = variablesArgsSchema.parse(args);
  return asJson(await callNeovim('dap_get_variables', { frame_id }, rpc_port));
}

export async function handleDapSetBreakpoint(args: any): Promise<any> {
  const { file, line, condition, rpc_port } = setBreakpointArgsSchema.parse(args);
  // Path shape only; whether it exists is decided by Neovim, whose cwd may be a worktree this
  // process cannot see.
  validateFilePath({ filepath: file });
  return asJson(await callNeovim('dap_set_breakpoint', { file, line, condition }, rpc_port));
}

export async function handleDapEvaluate(args: any): Promise<any> {
  const { expression, frame_id, rpc_port } = evaluateArgsSchema.parse(args);
  return asJson(await callNeovim('dap_evaluate', { expression, frame_id }, rpc_port));
}
