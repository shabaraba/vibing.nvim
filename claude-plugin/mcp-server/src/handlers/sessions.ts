import { z } from 'zod';
import { searchSessions, readSession } from '../session-logs.js';

const backend = z.enum(['claude', 'codex']);
const searchSchema = z.object({
  backend: backend.optional(),
  query: z.string().max(1000).optional(),
  session_id: z.string().min(1).optional(),
  working_dir: z.string().min(1).optional(),
  limit: z.number().int().min(1).max(100).default(20),
});
const readSchema = z.object({
  backend,
  session_id: z.string().min(1),
  offset: z.number().int().min(0).default(0),
  limit: z.number().int().min(1).max(100).default(20),
  max_chars: z.number().int().min(1).max(20000).default(4000),
});
const result = (value: unknown) => ({
  content: [{ type: 'text' as const, text: JSON.stringify(value, null, 2) }],
});

export async function handleSessionSearch(args: unknown) {
  return result(await searchSessions(searchSchema.parse(args ?? {})));
}

export async function handleSessionRead(args: unknown) {
  return result(await readSession(readSchema.parse(args)));
}
