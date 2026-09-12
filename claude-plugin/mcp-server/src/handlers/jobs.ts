import path from 'node:path';
import { z } from 'zod';
import { callNeovim } from '../rpc.js';

const jobIdSchema = z.string().min(1);
const tailLinesSchema = z.number().int().min(0).max(200).optional();

const startSchema = z.object({
  command: z
    .array(
      z
        .string()
        .min(1)
        .refine((value) => !/[\r\n]/.test(value), {
          message: 'command arguments must not contain line breaks',
        })
    )
    .min(1)
    .max(100),
  name: z
    .string()
    .min(1)
    .max(100)
    .refine((value) => !/[\r\n]/.test(value), { message: 'name must not contain line breaks' })
    .optional(),
  cwd: z.string().min(1).optional(),
  from_bufnr: z.number().int().positive(),
  notify: z.enum(['always', 'on_failure', 'never', 'passive']).optional(),
  env: z.record(z.string().min(1), z.string()).optional(),
  ready_pattern: z.string().min(1).max(500).optional(),
  ready_timeout_ms: z.number().int().min(1).max(3600000).optional(),
  rpc_port: z.number().optional(),
});

const statusSchema = z.object({
  job_id: jobIdSchema,
  tail_lines: tailLinesSchema,
  rpc_port: z.number().optional(),
});

const stopSchema = z.object({ job_id: jobIdSchema, rpc_port: z.number().optional() });

const waitSchema = z.object({
  job_id: jobIdSchema,
  timeout_ms: z.number().int().min(0).max(25000).optional(),
  tail_lines: tailLinesSchema,
  until: z.enum(['exit', 'ready']).optional(),
  rpc_port: z.number().optional(),
});

const listSchema = z.object({ rpc_port: z.number().optional() });

function response(result: unknown) {
  return { content: [{ type: 'text', text: JSON.stringify(result, null, 2) }] };
}

export async function handleJobStart(args: unknown) {
  const parsed = startSchema.parse(args);
  const baseCwd = process.cwd();
  const cwd = parsed.cwd ? path.resolve(baseCwd, parsed.cwd) : baseCwd;
  const result = await callNeovim(
    'job_start',
    {
      command: parsed.command,
      name: parsed.name,
      cwd,
      base_cwd: baseCwd,
      from_bufnr: parsed.from_bufnr,
      notify: parsed.notify,
      env: parsed.env,
      ready_pattern: parsed.ready_pattern,
      ready_timeout_ms: parsed.ready_timeout_ms,
    },
    parsed.rpc_port
  );
  return response(result);
}

export async function handleJobStatus(args: unknown) {
  const parsed = statusSchema.parse(args);
  return response(
    await callNeovim(
      'job_status',
      { job_id: parsed.job_id, tail_lines: parsed.tail_lines },
      parsed.rpc_port
    )
  );
}

export async function handleJobList(args: unknown) {
  const parsed = listSchema.parse(args ?? {});
  return response(await callNeovim('job_list', {}, parsed.rpc_port));
}

export async function handleJobStop(args: unknown) {
  const parsed = stopSchema.parse(args);
  return response(await callNeovim('job_stop', { job_id: parsed.job_id }, parsed.rpc_port));
}

export async function handleJobWait(args: unknown) {
  const parsed = waitSchema.parse(args);
  return response(
    await callNeovim(
      'job_wait',
      {
        job_id: parsed.job_id,
        timeout_ms: parsed.timeout_ms,
        tail_lines: parsed.tail_lines,
        until: parsed.until,
      },
      parsed.rpc_port
    )
  );
}
