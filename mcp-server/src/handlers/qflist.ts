import { callNeovim } from '../rpc.js';
import { validateFilePath } from '../validation/schema.js';
import { z } from 'zod';

const qflistItemSchema = z.object({
  filename: z.string().min(1),
  lnum: z.number().int().positive(),
  col: z.number().int().positive().optional(),
  text: z.string().optional(),
});

const setQflistArgsSchema = z.object({
  items: z.array(qflistItemSchema).min(1),
  title: z.string().optional(),
  open: z.boolean().optional(),
  rpc_port: z.number(),
});

/**
 * Handler for nvim_set_qflist
 *
 * Only the path *shape* is checked here — traversal and sensitive prefixes. Whether a path exists
 * is decided by `handlers/qflist.lua`, because a relative path resolves against the target
 * instance's cwd (a worktree, often enough), which this process has no view of.
 *
 * One bad stop fails the whole call rather than being dropped. Unlike nvim_ask_user_question,
 * this tool's result does come back to the model, so a hard error is something it can act on;
 * a silently shortened tour is not.
 */
export async function handleSetQflist(args: any): Promise<any> {
  const { items, title, open, rpc_port } = setQflistArgsSchema.parse(args);

  for (const item of items) {
    validateFilePath({ filepath: item.filename });
  }

  const result = await callNeovim('set_qflist', { items, title, open }, rpc_port);
  const opened = open ? ' and opened' : '';

  return {
    content: [
      {
        type: 'text',
        text: `Quickfix list "${result.title}" set with ${result.count} stop(s)${opened}.`,
      },
    ],
    _meta: result,
  };
}
